import AVFoundation
import Combine
import QuartzCore

/// Boucle vidéo temps réel, hors main thread.
///
/// Le timer tourne à cadence fixe tant que le live est ouvert et envoie TOUJOURS une image
/// à l'encodeur : source active, fondu de transition, ou écran brandé si la source est muette.
/// Changer de source = changer `scene`. L'éditeur RTMP ne voit jamais la différence.
final class VideoPipeline: @unchecked Sendable {
    let fps: Int
    let preview = AVSampleBufferDisplayLayer()

    private let compositor: Compositor
    private let publisher: LivePublisher
    private let queue = DispatchQueue(label: "roamcast.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    private var sources: [VideoSourceID: LatestFrameBox] = [:]
    private var scene: SceneKind = .live(.iPhoneCamera)
    private var sendToPublisher = false

    private var frameIndex: Int64 = 0
    /// Au-delà, une source est considérée muette → écran de secours.
    private let maxFrameAge: CFTimeInterval = 0.5

    init(profile: QualityProfile, publisher: LivePublisher) {
        fps = profile.fps
        compositor = Compositor(width: profile.width, height: profile.height)
        self.publisher = publisher
        preview.videoGravity = .resizeAspect
    }

    func register(_ id: VideoSourceID, frames: LatestFrameBox) {
        lock.lock(); sources[id] = frames; lock.unlock()
    }

    func setScene(_ s: SceneKind) { lock.lock(); scene = s; lock.unlock() }
    func setSending(_ on: Bool) { lock.lock(); sendToPublisher = on; lock.unlock() }
    func updateOverlay(_ m: OverlayModel) { queue.async { [compositor] in compositor.updateOverlay(m) } }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        lock.lock()
        let scene = self.scene
        let sending = sendToPublisher
        var sourceFrame: CVPixelBuffer?
        if case .live(let id) = scene { sourceFrame = sources[id]?.latest(maxAge: maxFrameAge) }
        lock.unlock()

        let now = CACurrentMediaTime()
        guard let out = compositor.compose(scene: scene, source: sourceFrame, now: now) else { return }

        // Horodatage monotone basé sur l'horloge hôte, commun avec l'audio (AVAudioTime.hostTime).
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        guard let sb = SampleBufferFactory.make(from: out, pts: pts, fps: fps) else { return }
        frameIndex += 1

        if sending { publisher.appendVideo(sb) }

        // Aperçu opérateur : on montre exactement ce que voient les viewers, à 15 i/s pour épargner le GPU.
        if frameIndex % 2 == 0 {
            DispatchQueue.main.async { [preview] in
                if preview.status == .failed { preview.flush() }
                preview.enqueue(sb)
            }
        }
    }
}

/// Façade @MainActor pour l'UI : état RTMP, bitrate adaptatif, reconnexion (CDC §11).
@MainActor
final class StreamingEngine: ObservableObject {
    @Published private(set) var publisherState: PublisherState = .idle
    @Published private(set) var scene: SceneKind = .live(.iPhoneCamera)
    @Published private(set) var currentBitrate: Int = 0
    @Published private(set) var sentBitrate: Int = 0
    var adaptiveBitrateEnabled = true

    let pipeline: VideoPipeline
    let publisher: LivePublisher
    private(set) var profile: QualityProfile
    private var abr: AdaptiveBitrateController

    private var statsTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var ingestURL = ""
    private var streamKey = ""
    /// Tant que c'est vrai, toute déconnexion déclenche une reconnexion.
    private var wantsLive = false

    init(publisher: LivePublisher, profile: QualityProfile = .normal) {
        self.publisher = publisher
        self.profile = profile
        pipeline = VideoPipeline(profile: .normal, publisher: publisher)   // rendu toujours 1080p30
        abr = AdaptiveBitrateController(start: profile.startBitrate,
                                        min: profile.minBitrate, max: profile.maxBitrate)
        publisher.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
    }

    func register(_ source: VideoSource) { pipeline.register(source.id, frames: source.frames) }

    /// Choix du profil avant le live. Le compositeur reste en 1080p ;
    /// l'encodeur met à l'échelle (720p en Éco).
    func setProfile(_ p: QualityProfile) {
        guard !wantsLive else { return }
        profile = p
        abr = AdaptiveBitrateController(start: p.startBitrate, min: p.minBitrate, max: p.maxBitrate)
    }

    /// Aperçu sans être à l'antenne (écran de préparation).
    func startPreview() { pipeline.start() }

    func goLive(ingestURL: String, streamKey: String) async throws {
        self.ingestURL = ingestURL
        self.streamKey = streamKey
        wantsLive = true
        await publisher.configure(width: profile.width, height: profile.height,
                                  fps: profile.fps, bitrate: abr.target)
        currentBitrate = abr.target
        pipeline.start()
        try await publisher.connect(url: ingestURL, streamKey: streamKey)
        pipeline.setSending(true)
        startStatsLoop()
    }

    /// SEUL chemin qui ferme le RTMP. Appelé uniquement par SessionManager en ENDING.
    func endLive() async {
        wantsLive = false
        reconnectTask?.cancel()
        statsTask?.cancel()
        pipeline.setSending(false)
        await publisher.disconnect()
    }

    // MARK: - Scènes

    func show(_ newScene: SceneKind) {
        scene = newScene
        pipeline.setScene(newScene)
    }

    func updateOverlay(_ model: OverlayModel) { pipeline.updateOverlay(model) }

    // MARK: - Réseau

    private func startStatsLoop() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.sampleNetwork()
            }
        }
    }

    private func sampleNetwork() async {
        let s = await publisher.stats()
        sentBitrate = s.sentBitsPerSecond
        guard adaptiveBitrateEnabled, publisherState == .live else { return }
        let decision = abr.update(.init(sentBitsPerSecond: s.sentBitsPerSecond,
                                        queuedBytes: s.queuedBytes,
                                        publisherReportedCongestion: s.insufficientBandwidth))
        switch decision {
        case .keep: break
        case .decrease(let b), .increase(let b):
            AppLog.log("Réseau", "Bitrate → \(Format.bitrate(b)) (envoyé : \(Format.bitrate(s.sentBitsPerSecond)))")
            currentBitrate = b
            await publisher.setVideoBitrate(b)
        }
    }

    private func handle(_ state: PublisherState) {
        // Pendant une reconnexion, on garde l'affichage « reconnexion n » plutôt que « failed ».
        if reconnectTask != nil, case .failed = state { return }
        AppLog.log("RTMP", "\(state)")
        publisherState = state
        switch state {
        case .failed, .closed:
            if wantsLive { scheduleReconnect() }
        default: break
        }
    }

    /// Reconnexion automatique (CDC §11.2) : backoff 1, 2, 4, 8, 10, 10… s.
    /// Le rendu continue pendant ce temps : dès que ça reconnecte, l'image repart.
    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        pipeline.setSending(false)
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while let self, self.wantsLive, !Task.isCancelled {
                attempt += 1
                self.publisherState = .reconnecting(attempt: attempt)
                let delay = min(10, 1 << min(attempt - 1, 4))
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                // Si ça a coupé, le réseau est probablement faible : on repart plus bas.
                self.abr.reset(start: max(self.profile.minBitrate, self.abr.target * 3 / 4))
                await self.publisher.configure(width: self.profile.width, height: self.profile.height,
                                               fps: self.profile.fps, bitrate: self.abr.target)
                do {
                    try await self.publisher.connect(url: self.ingestURL, streamKey: self.streamKey)
                    self.currentBitrate = self.abr.target
                    self.pipeline.setSending(true)
                    break
                } catch { continue }
            }
            self?.reconnectTask = nil
        }
    }
}
