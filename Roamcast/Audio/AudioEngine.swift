import AVFoundation
import Combine

/// Mix audio (CDC §7) :
///
///   Micro (DJI Mic Mini BT / iPhone) → voiceMixer ─┐
///                                                   ├→ broadcastMixer ─tap→ AAC → Twitch
///   Musique (AVAudioPlayerNode)      → musicMixer ─┘        │
///                                                   mainMixer (volume 0) → sortie
///
/// Le mainMixer est muet : on n'entend pas sa propre voix dans le haut-parleur (larsen).
final class AudioEngine: ObservableObject {
    enum InputKind: String { case djiMic = "DJI Mic Mini", bluetooth = "Micro Bluetooth", builtIn = "Micro iPhone" }

    @Published private(set) var input: InputKind = .builtIn
    @Published private(set) var micLevelDB: Float = -160
    @Published private(set) var duckGainDB: Float = 0
    @Published var micVolume: Float = 1 { didSet { voiceMixer.outputVolume = micVolume } }
    @Published var musicVolume: Float = 0.35
    @Published var masterVolume: Float = 1 { didSet { broadcastMixer.outputVolume = masterVolume } }

    let engine = AVAudioEngine()
    let musicPlayer = AVAudioPlayerNode()
    private let voiceMixer = AVAudioMixerNode()
    private let musicMixer = AVAudioMixerNode()
    private let broadcastMixer = AVAudioMixerNode()

    private var ducker: Ducker
    private let duckLock = NSLock()
    /// Reçoit l'audio final à encoder (PCM + instant sur l'horloge hôte, la même que la vidéo).
    var onBroadcastBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    init(ducking: DuckingSettings) {
        ducker = Ducker(settings: ducking)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged),
                                               name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    func setDucking(_ s: DuckingSettings) { duckLock.lock(); ducker.settings = s; duckLock.unlock() }

    // MARK: - Session

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .allowBluetooth = profil HFP : seul moyen d'utiliser un micro BT comme ENTRÉE.
        // Conséquence : bande passante réduite (voir README, risque n°2).
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .defaultToSpeaker]
        if #available(iOS 26.0, *) {
            // Enregistrement BT haute qualité si le périphérique le supporte (à valider avec le Mic Mini).
            options.insert(.bluetoothHighQualityRecording)
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        selectPreferredInput()
    }

    /// DJI Mic Mini en priorité, sinon tout micro BT, sinon micro interne (secours).
    func selectPreferredInput() {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        let bt = inputs.filter { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE }
        let chosen = bt.first { $0.portName.localizedCaseInsensitiveContains("DJI") } ?? bt.first
            ?? inputs.first { $0.portType == .builtInMic }
        try? session.setPreferredInput(chosen)
        AppLog.log("Audio", "Entrée : \(chosen?.portName ?? "aucune") (\(chosen?.portType.rawValue ?? "-")) · \(Int(session.sampleRate)) Hz")
        DispatchQueue.main.async {
            if let chosen, chosen.portType != .builtInMic {
                self.input = chosen.portName.localizedCaseInsensitiveContains("DJI") ? .djiMic : .bluetooth
            } else {
                self.input = .builtIn
            }
        }
    }

    // MARK: - Graphe

    private var graphBuilt = false

    func start() throws {
        if graphBuilt {
            if !engine.isRunning { try engine.start() }
            return
        }
        graphBuilt = true
        [voiceMixer, musicMixer, broadcastMixer, musicPlayer].forEach { engine.attach($0) }

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let mixFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

        engine.connect(engine.inputNode, to: voiceMixer, format: inputFormat)
        engine.connect(musicPlayer, to: musicMixer, format: nil)
        engine.connect(voiceMixer, to: broadcastMixer, format: mixFormat)
        engine.connect(musicMixer, to: broadcastMixer, format: mixFormat)
        engine.connect(broadcastMixer, to: engine.mainMixerNode, format: mixFormat)
        engine.mainMixerNode.outputVolume = 0

        voiceMixer.outputVolume = micVolume
        broadcastMixer.outputVolume = masterVolume
        musicMixer.outputVolume = musicVolume

        // 1) Détection de voix → ducking
        voiceMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.processVoice(buffer)
        }
        // 2) Sortie broadcast → encodeur
        broadcastMixer.installTap(onBus: 0, bufferSize: 1024, format: mixFormat) { [weak self] buffer, when in
            // Même horloge que la vidéo (host time) → synchro lèvres correcte.
            let time = when.isHostTimeValid ? when : AVAudioTime(hostTime: mach_absolute_time())
            self?.onBroadcastBuffer?(buffer, time)
        }

        engine.prepare()
        try engine.start()
    }

    private func processVoice(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        let db = Ducker.rmsDB(ch, count: n)
        let dt = Float(n) / Float(buffer.format.sampleRate)
        duckLock.lock()
        let gain = ducker.process(micLevelDB: db, dt: dt)
        let gainDB = ducker.currentGainDB
        duckLock.unlock()
        musicMixer.outputVolume = musicVolume * gain
        DispatchQueue.main.async {
            self.micLevelDB = db
            self.duckGainDB = gainDB
        }
    }

    // MARK: - Événements

    @objc private func routeChanged(_ note: Notification) {
        // Le DJI Mic Mini se déconnecte (batterie, distance) → bascule immédiate sur le micro iPhone.
        // Il se reconnecte → on le reprend. Le live ne s'arrête jamais pour ça.
        selectPreferredInput()
        if !engine.isRunning { try? engine.start() }
    }

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }
}
