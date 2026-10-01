import AVFoundation

/// Caméra arrière de l'iPhone (mode Balade).
/// Vidéo uniquement : l'audio est géré par AudioEngine, et la session de capture
/// ne doit surtout pas reconfigurer AVAudioSession (sinon le DJI Mic Mini saute).
final class CameraManager: NSObject, VideoSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    let id: VideoSourceID = .iPhoneCamera
    let frames = LatestFrameBox()

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "roamcast.camera", qos: .userInitiated)
    private var configured = false

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in session.stopRunning(); frames.clear() }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration(); configured = true }

        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        try? device.lockForConfiguration()
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.unlockForConfiguration()

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        if let conn = output.connection(with: .video) {
            // Paysage 16:9 (CDC §2).
            if conn.isVideoRotationAngleSupported(0) { conn.videoRotationAngle = 0 }
            // En marchant, la stabilisation fait toute la différence.
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = .cinematicExtended
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frames.put(pb)
    }
}
