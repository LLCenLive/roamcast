#if canImport(RTMPHaishinKit)
import AVFoundation
import HaishinKit
import RTMPHaishinKit
import VideoToolbox

/// Adaptateur HaishinKit 2.2.x (RTMP). Aligné sur l'API réelle de la 2.2.5 :
/// - `RTMPConnection` / `RTMPStream` sont des acteurs → tout passe par `await` ;
/// - la vidéo NON compressée va dans `append(CMSampleBuffer)` (encodage H.264 par HaishinKit) ;
/// - l'audio PCM va dans `append(AVAudioBuffer, when:)` (un CMSampleBuffer audio serait ignoré) ;
/// - les statistiques réseau arrivent via une « stratégie de bitrate » qu'on détourne
///   en simple capteur : c'est notre `AdaptiveBitrateController` qui décide.
final class HaishinKitPublisher: LivePublisher {
    var onStateChange: ((PublisherState) -> Void)?

    private let connection: RTMPConnection
    private let stream: RTMPStream
    private let tap = NetworkReportTap()
    private var statusTask: Task<Void, Never>?

    /// File d'envoi unique : garantit l'ordre des images et des buffers audio
    /// (des `Task {}` séparées pourraient arriver dans le désordre sur l'acteur).
    private enum Item: @unchecked Sendable {
        case video(CMSampleBuffer)
        case audio(AVAudioPCMBuffer, AVAudioTime)
    }
    private let queue: AsyncStream<Item>.Continuation
    private let pump: Task<Void, Never>

    init() {
        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)
        self.connection = connection
        self.stream = stream
        let (items, continuation) = AsyncStream<Item>.makeStream(bufferingPolicy: .bufferingNewest(90))
        queue = continuation
        pump = Task {
            for await item in items {
                switch item {
                case .video(let sb): await stream.append(sb)
                case .audio(let buf, let when): await stream.append(buf, when: when)
                }
            }
        }
    }

    deinit {
        queue.finish()
        pump.cancel()
        statusTask?.cancel()
    }

    func configure(width: Int, height: Int, fps: Int, bitrate: Int) async {
        var video = VideoCodecSettings(
            videoSize: CGSize(width: width, height: height),
            bitRate: bitrate,
            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
            scalingMode: .trim,
            bitRateMode: .average,
            maxKeyFrameIntervalDuration: 2,          // Twitch : une image clé toutes les 2 s
            expectedFrameRate: Double(fps)
        )
        video.allowFrameReordering = false           // pas de B-frames : plus robuste en mobilité
        try? await stream.setVideoSettings(video)
        try? await stream.setAudioSettings(AudioCodecSettings(bitRate: 160_000))   // AAC 160 kb/s
        await stream.setBitRateStrategy(tap)
    }

    func connect(url: String, streamKey: String) async throws {
        onStateChange?(.connecting)
        if await connection.connected { try? await connection.close() }
        _ = try await connection.connect(url)
        _ = try await stream.publish(streamKey)
        onStateChange?(.live)
        observeStatus()
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) { queue.yield(.video(sampleBuffer)) }

    func appendAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        // Le tap d'AVAudioEngine réutilise ses buffers : on copie avant de différer l'envoi.
        guard let copy = buffer.deepCopy() else { return }
        queue.yield(.audio(copy, when))
    }

    func setVideoBitrate(_ bitsPerSecond: Int) async {
        var video = await stream.videoSettings
        video.bitRate = bitsPerSecond
        try? await stream.setVideoSettings(video)
    }

    func stats() async -> PublisherStats {
        let (report, insufficient) = await tap.consume()
        return PublisherStats(sentBitsPerSecond: (report?.currentBytesOutPerSecond ?? 0) * 8,
                              queuedBytes: report?.currentQueueBytesOut ?? 0,
                              insufficientBandwidth: insufficient)
    }

    func disconnect() async {
        statusTask?.cancel()
        statusTask = nil
        _ = try? await stream.close()
        try? await connection.close()
        onStateChange?(.closed)
    }

    private func observeStatus() {
        statusTask?.cancel()
        let connection = self.connection
        statusTask = Task { [weak self] in
            for await status in await connection.status {
                switch status.code {
                case RTMPConnection.Code.connectClosed.rawValue,
                     RTMPConnection.Code.connectFailed.rawValue,
                     RTMPConnection.Code.connectIdleTimeOut.rawValue,
                     RTMPConnection.Code.connectNetworkChange.rawValue,
                     RTMPConnection.Code.connectRejected.rawValue:
                    let cb = self?.onStateChange
                    await MainActor.run { cb?(.failed(status.code)) }
                default:
                    break
                }
            }
        }
    }
}

/// Capteur de statistiques réseau : reçoit les rapports de HaishinKit chaque seconde
/// sans jamais toucher au bitrate.
actor NetworkReportTap: StreamBitRateStrategy {
    nonisolated let mamimumVideoBitRate: Int = 0   // (sic, orthographe de l'API HaishinKit)
    nonisolated let mamimumAudioBitRate: Int = 0
    private var last: NetworkMonitorReport?
    private var insufficient = false

    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status(let report):
            last = report
        case .publishInsufficientBWOccured(let report):
            last = report
            insufficient = true
        case .reset:
            last = nil
        }
    }

    func consume() -> (NetworkMonitorReport?, Bool) {
        let flag = insufficient
        insufficient = false
        return (last, flag)
    }
}

private extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sData = s.mData, let dData = d.mData else { continue }
            memcpy(dData, sData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }
}
#endif
