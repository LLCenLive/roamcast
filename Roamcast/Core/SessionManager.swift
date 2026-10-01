import Combine
import Foundation
import UIKit

/// Chef d'orchestre de la session (CDC §3, §14).
/// Toute action utilisateur passe par ici ; seul `stop()` peut fermer le RTMP.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    @Published var preset: LivePreset
    @Published private(set) var droneChecklist = DroneChecklist()
    @Published private(set) var droneTelemetry = DroneTelemetry()
    @Published private(set) var liveStartedAt: Date?
    @Published private(set) var viewers: Int?
    @Published var lastError: String? {
        didSet { if let e = lastError { AppLog.log("Erreur", e) } }
    }

    let engine: StreamingEngine
    let audio: AudioEngine
    let music: MusicManager
    let location = LocationManager()
    let device = DeviceMonitor()
    let camera = CameraManager()
    let drone: DroneLink
    let auth: TwitchAuth
    let twitch: TwitchAPI
    let chat = TwitchChat()

    private var machine = SessionStateMachine()
    private var bag = Set<AnyCancellable>()
    private var overlayTimer: Timer?
    private var viewersTask: Task<Void, Never>?
    private var droneLostSince: Date?
    /// Mode essai : tout fonctionne (caméra, drone, audio, overlay) mais rien ne part sur Twitch.
    @Published var dryRun = true {
        didSet { if !state.isOnAir { switchable.dryRun = dryRun } }
    }
    private let switchable: SwitchablePublisher

    init(twitchClientID: String) {
        let initial = LivePreset.defaults[0]
        preset = initial
        #if canImport(HaishinKit)
        let publisher = SwitchablePublisher(real: HaishinKitPublisher())
        #else
        let publisher = SwitchablePublisher(real: nil)
        #endif
        switchable = publisher
        engine = StreamingEngine(publisher: publisher, profile: initial.quality)
        let audioEngine = AudioEngine(ducking: initial.ducking)
        audio = audioEngine
        music = MusicManager(player: audioEngine.musicPlayer)
        #if canImport(DJISDK) && !targetEnvironment(simulator)
        drone = DJIManager()
        #else
        drone = SimulatedDrone()
        #endif
        let twitchAuth = TwitchAuth(clientID: twitchClientID)
        auth = twitchAuth
        twitch = TwitchAPI(auth: twitchAuth)

        AppLog.log("App", AppInfo.summary)
        engine.register(camera)
        engine.register(drone)
        audio.onBroadcastBuffer = { [publisher] sb in publisher.appendAudio(sb) }

        drone.checklistPublisher.receive(on: RunLoop.main)
            .sink { [weak self] c in self?.droneChecklist = c; self?.watchDroneLink(c) }
            .store(in: &bag)
        drone.telemetryPublisher.receive(on: RunLoop.main)
            .sink { [weak self] t in self?.droneTelemetry = t }
            .store(in: &bag)
        $preset.map(\.locationMode).removeDuplicates()
            .sink { [weak self] m in self?.location.mode = m }
            .store(in: &bag)
        $preset.map(\.ducking).removeDuplicates()
            .sink { [weak self] d in self?.audio.setDucking(d) }
            .store(in: &bag)
    }

    // MARK: - Parcours (CDC §3)

    func openSetup() {
        guard transition(.openSetup) else { return }
        do {
            try audio.configureSession()
            try audio.start()
        } catch { lastError = "Audio : \(error.localizedDescription)" }
        camera.start()
        location.start()
        engine.show(.live(.iPhoneCamera))
        engine.startPreview()
        startOverlayLoop()
    }

    func goLive() async {
        guard auth.isSignedIn || dryRun else {
            lastError = "Connecte-toi à Twitch pour diffuser, ou active le mode essai."
            return
        }
        switchable.dryRun = dryRun
        do {
            // 1) Métadonnées d'abord (API) – indépendant du RTMP. En mode essai, on ne touche pas à la chaîne.
            let key: String
            if dryRun {
                key = "dry-run"
            } else {
                try await applyLiveInfo()
                // 2) Puis la vidéo.
                key = try await twitch.streamKey()
            }
            engine.setProfile(preset.quality)
            engine.adaptiveBitrateEnabled = preset.adaptiveBitrate
            try await engine.goLive(ingestURL: TwitchAPI.defaultIngest, streamKey: key)
            guard transition(.goLive) else { return }
            liveStartedAt = Date()
            location.resetTrack()
            UIApplication.shared.isIdleTimerDisabled = true
            startViewersLoop()
            if let me = twitch.me, let token = try? await auth.validToken() {
                chat.connect(channel: me.login, login: me.login, token: token)
            }
        } catch {
            lastError = "Impossible de lancer le live : \(error.localizedDescription)"
        }
    }

    /// « Passer au drone » (CDC §8) : écran brandé, micro + musique conservés.
    func requestDrone() {
        guard transition(.requestDrone) else { return }
        engine.show(.slate(message: "Préparation du drone…"))
        drone.prepare()
        drone.start()
    }

    func cancelDrone() {
        guard transition(.cancelDrone) else { return }
        engine.show(.live(.iPhoneCamera))
    }

    /// Bascule effective vers le flux du Mini 2. Décision humaine, jamais automatique.
    func switchToDrone() {
        guard droneChecklist.readyToSwitch, transition(.droneReady) else { return }
        location.markDroneTakeoff()
        engine.show(.live(.drone))
    }

    /// Retour caméra iPhone (CDC §10). Le drone peut ensuite être débranché.
    func backToWalk() {
        guard transition(.backToWalk) else { return }
        engine.show(.live(.iPhoneCamera))
        drone.stop()
    }

    /// SEUL point de fermeture du RTMP (confirmation demandée côté UI).
    func stop() async {
        guard transition(.stop) else { return }
        engine.show(.slate(message: "Merci d'avoir suivi la balade !"))
        try? await Task.sleep(nanoseconds: 3_000_000_000)   // laisse le mot de fin passer
        await engine.endLive()
        chat.disconnect()
        viewersTask?.cancel()
        drone.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        _ = transition(.stopped)
    }

    /// Retour à l'accueil après la fin d'un live (ou abandon de la préparation).
    func reset() {
        guard transition(.reset) else { return }
        camera.stop()
        location.stop()
        engine.show(.live(.iPhoneCamera))
        liveStartedAt = nil
        viewers = nil
    }

    // MARK: - Twitch à chaud (CDC §4.3)

    func applyLiveInfo() async throws {
        try await twitch.updateChannel(.init(title: preset.title,
                                             game_id: preset.category?.id,
                                             broadcaster_language: preset.language,
                                             tags: preset.tags))
    }

    // MARK: - Interne

    @discardableResult
    private func transition(_ e: SessionEvent) -> Bool {
        do { state = try machine.send(e); AppLog.log("Session", "→ \(state.rawValue)"); return true }
        catch { return false }
    }

    /// Drone perdu en vol : l'écran de secours s'affiche tout seul (compositeur),
    /// et après 5 s sans retour on repasse sur l'iPhone. Le live, lui, ne bouge pas.
    private func watchDroneLink(_ c: DroneChecklist) {
        guard state == .drone else { droneLostSince = nil; return }
        if c.videoReceiving { droneLostSince = nil; return }
        if droneLostSince == nil {
            droneLostSince = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.state == .drone, let since = self.droneLostSince,
                      Date().timeIntervalSince(since) >= 5 else { return }
                if self.transition(.cancelDrone) { self.engine.show(.live(.iPhoneCamera)) }
            }
        }
    }

    private func startViewersLoop() {
        viewersTask?.cancel()
        viewersTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.auth.isSignedIn {
                    self.viewers = (try? await self.twitch.liveStream())?.viewer_count
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func startOverlayLoop() {
        overlayTimer?.invalidate()
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushOverlay() }
        }
    }

    private func pushOverlay() {
        var m = OverlayModel()
        m.location = location.publicLocation.label
        if let start = liveStartedAt { m.elapsed = Format.duration(Date().timeIntervalSince(start)) }
        if location.distanceMeters > 0 { m.distance = Format.distance(location.distanceMeters) }
        if state == .drone {
            let t = droneTelemetry
            m.droneAltitude = "\(Int(t.altitudeMeters.rounded())) m"
            m.droneDistance = Format.distance(t.distanceToHomeMeters)
            m.droneSpeed = "\(Int((t.horizontalSpeed * 3.6).rounded())) km/h"
            m.droneBattery = t.batteryPercent.map { "\($0) %" }
        }
        m.nowPlaying = music.isPlaying ? music.current?.title : nil
        engine.updateOverlay(m)
    }
}

enum Format {
    static func duration(_ s: TimeInterval) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }
    static func distance(_ m: Double) -> String {
        m < 1000 ? "\(Int(m.rounded())) m" : String(format: "%.1f km", m / 1000).replacingOccurrences(of: ".", with: ",")
    }
    static func bitrate(_ bps: Int) -> String {
        String(format: "%.1f Mb/s", Double(bps) / 1_000_000).replacingOccurrences(of: ".", with: ",")
    }
}
