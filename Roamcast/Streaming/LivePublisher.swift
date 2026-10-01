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
    func appendVideo(_ sampleBuffer: CMSampleBuffer)
    func appendAudio(_ sampleBuffer: CMSampleBuffer)
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

#if canImport(HaishinKit)
import HaishinKit
import VideoToolbox
#if canImport(RTMPHaishinKit)
import RTMPHaishinKit
#endif

/// Adaptateur HaishinKit 2.x.
/// ⚠️ SEUL fichier à réaligner si l'API HaishinKit de la version épinglée diffère
/// (l'API a beaucoup bougé entre 1.x et 2.x : acteurs, async, découpage en modules).
final class HaishinKitPublisher: LivePublisher {
    var onStateChange: ((PublisherState) -> Void)?

    private let connection = RTMPConnection()
    private lazy var stream = RTMPStream(connection: connection)
    private var lastBytesOut: Int64 = 0
    private var lastSample = Date()

    func configure(width: Int, height: Int, fps: Int, bitrate: Int) async {
        var video = await stream.videoSettings
        video.videoSize = CGSize(width: width, height: height)
        video.bitRate = bitrate
        video.maxKeyFrameIntervalDuration = 2          // Twitch : keyframe toutes les 2 s
        video.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
        try? await stream.setVideoSettings(video)

        var audio = await stream.audioSettings
        audio.bitRate = 160_000                        // AAC 160 kb/s
        try? await stream.setAudioSettings(audio)
        try? await stream.setFrameRate(Float64(fps))
    }

    func connect(url: String, streamKey: String) async throws {
        onStateChange?(.connecting)
        _ = try await connection.connect(url)
        _ = try await stream.publish(streamKey)
        onStateChange?(.live)
        Task { [weak self] in await self?.observeStatus() }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        Task { await stream.append(sampleBuffer) }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        Task { await stream.append(sampleBuffer) }
    }

    func setVideoBitrate(_ bitsPerSecond: Int) async {
        var video = await stream.videoSettings
        video.bitRate = bitsPerSecond
        try? await stream.setVideoSettings(video)
    }

    func stats() async -> PublisherStats {
        // À vérifier selon la version : les compteurs d'octets sont exposés par RTMPConnection.
        let total = await connection.totalBytesOut
        let now = Date()
        let dt = max(0.001, now.timeIntervalSince(lastSample))
        let bps = Int(Double(total - lastBytesOut) * 8 / dt)
        lastBytesOut = total
        lastSample = now
        return PublisherStats(sentBitsPerSecond: bps, queuedBytes: 0, insufficientBandwidth: false)
    }

    func disconnect() async {
        _ = try? await stream.close()
        try? await connection.close()
        onStateChange?(.closed)
    }

    private func observeStatus() async {
        for await status in await connection.status {
            switch status.code {
            case RTMPConnection.Code.connectClosed.rawValue,
                 RTMPConnection.Code.connectFailed.rawValue:
                onStateChange?(.failed(status.code))
            default: break
            }
        }
    }
}
#endif

/// Éditeur factice : permet de développer l'UI, la bascule de sources et l'audio
/// sans réseau ni Twitch (simulateur, avion…).
final class DryRunPublisher: LivePublisher {
    var onStateChange: ((PublisherState) -> Void)?
    private var bitrate = 0
    private(set) var videoFrames = 0
    private(set) var audioBuffers = 0

    func configure(width: Int, height: Int, fps: Int, bitrate: Int) async { self.bitrate = bitrate }
    func connect(url: String, streamKey: String) async throws { onStateChange?(.live) }
    func appendVideo(_ sampleBuffer: CMSampleBuffer) { videoFrames += 1 }
    func appendAudio(_ sampleBuffer: CMSampleBuffer) { audioBuffers += 1 }
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
    func appendAudio(_ sampleBuffer: CMSampleBuffer) { active.appendAudio(sampleBuffer) }
    func setVideoBitrate(_ bitsPerSecond: Int) async { await active.setVideoBitrate(bitsPerSecond) }
    func stats() async -> PublisherStats { await active.stats() }
    func disconnect() async { await active.disconnect() }
}
