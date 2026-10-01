import AVFoundation
import CoreMedia
import Foundation

enum PublisherState: Equatable {
    case idle
    case connecting
    case live
    case reconnecting(attempt: Int)
    case failed(String)
    case closed
}

struct PublisherStats {
    var sentBitsPerSecond: Int = 0
    var queuedBytes: Int = 0
    var insufficientBandwidth = false
}

/// Couche RTMP isolée (CDC §13) : le reste de l'app ne connaît que ce protocole.
/// Permet de commencer avec HaishinKit et de le remplacer plus tard sans rien toucher d'autre.
protocol LivePublisher: AnyObject {
    var onStateChange: ((PublisherState) -> Void)? { get set }
    func configure(width: Int, height: Int, fps: Int, bitrate: Int) async
    func connect(url: String, streamKey: String) async throws
    /// Image NON compressée (BGRA) : l'éditeur encode lui-même en H.264.
    func appendVideo(_ sampleBuffer: CMSampleBuffer)
    /// PCM non compressé, horodaté sur l'horloge hôte.
    func appendAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime)
    func setVideoBitrate(_ bitsPerSecond: Int) async
    func stats() async -> PublisherStats
    func disconnect() async
}

enum SampleBufferFactory {
    static func make(from pixelBuffer: CVPixelBuffer, pts: CMTime, fps: Int) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer,
                                                 formatDescription: format,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sb)
        return sb
    }
}

/// Éditeur factice : permet de développer l'UI, la bascule de sources et l'audio
/// sans réseau ni Twitch.
final class DryRunPublisher: LivePublisher {
    var onStateChange: ((PublisherState) -> Void)?
    private var bitrate = 0
    private(set) var videoFrames = 0
    private(set) var audioBuffers = 0

    func configure(width: Int, height: Int, fps: Int, bitrate: Int) async { self.bitrate = bitrate }
    func connect(url: String, streamKey: String) async throws { onStateChange?(.live) }
    func appendVideo(_ sampleBuffer: CMSampleBuffer) { videoFrames += 1 }
    func appendAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) { audioBuffers += 1 }
    func setVideoBitrate(_ bitsPerSecond: Int) async { bitrate = bitsPerSecond }
    func stats() async -> PublisherStats { PublisherStats(sentBitsPerSecond: bitrate) }
    func disconnect() async { onStateChange?(.closed) }
}

/// Aiguillage entre le vrai éditeur RTMP et le mode essai, choisi dans l'app
/// (pas de variable d'environnement possible sans Xcode). Figé pendant le live.
final class SwitchablePublisher: LivePublisher {
    var onStateChange: ((PublisherState) -> Void)? {
        didSet { real?.onStateChange = onStateChange; dry.onStateChange = onStateChange }
    }
    var dryRun = true
    private let real: LivePublisher?
    private let dry = DryRunPublisher()
    private var active: LivePublisher { (dryRun ? nil : real) ?? dry }

    init(real: LivePublisher?) { self.real = real }

    func configure(width: Int, height: Int, fps: Int, bitrate: Int) async {
        await active.configure(width: width, height: height, fps: fps, bitrate: bitrate)
    }
    func connect(url: String, streamKey: String) async throws { try await active.connect(url: url, streamKey: streamKey) }
    func appendVideo(_ sampleBuffer: CMSampleBuffer) { active.appendVideo(sampleBuffer) }
    func appendAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) { active.appendAudio(buffer, when: when) }
    func setVideoBitrate(_ bitsPerSecond: Int) async { await active.setVideoBitrate(bitsPerSecond) }
    func stats() async -> PublisherStats { await active.stats() }
    func disconnect() async { await active.disconnect() }
}
