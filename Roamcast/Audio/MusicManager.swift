import AVFoundation
import Combine

/// Bibliothèque musicale locale (CDC §7.2) – fichiers importés depuis Fichiers,
/// copiés dans le conteneur de l'app. Aucune dépendance Spotify / Apple Music.
@MainActor
final class MusicManager: ObservableObject {
    struct Track: Identifiable, Codable, Equatable {
        var id = UUID()
        var fileName: String
        var title: String
    }

    @Published private(set) var library: [Track] = []
    @Published private(set) var queue: [Track] = []
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published var shuffle = false
    @Published var loop = true

    static let supportedExtensions = ["mp3", "aac", "m4a", "wav"]

    private let player: AVAudioPlayerNode
    private var index = 0
    /// Incrémenté à chaque changement manuel : ignore les callbacks de fin des fichiers interrompus.
    private var generation = 0

    private var folder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init(player: AVAudioPlayerNode) {
        self.player = player
        loadLibrary()
    }

    // MARK: - Import

    func importFiles(_ urls: [URL]) {
        for url in urls where Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = folder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { continue }
            library.append(Track(fileName: dest.lastPathComponent,
                                 title: url.deletingPathExtension().lastPathComponent))
        }
        saveLibrary()
        if queue.isEmpty { queue = library }
    }

    // MARK: - Transport

    func play() {
        if queue.isEmpty { queue = shuffle ? library.shuffled() : library }
        guard !queue.isEmpty else { return }
        if current == nil { startTrack(at: 0) } else { player.play(); isPlaying = true }
    }

    func pause() { player.pause(); isPlaying = false }
    func togglePlay() { isPlaying ? pause() : play() }
    func next() { advance(by: 1) }
    func previous() { advance(by: -1) }

    private func advance(by delta: Int) {
        guard !queue.isEmpty else { return }
        var i = index + delta
        if i >= queue.count {
            guard loop else { stop(); return }
            if shuffle { queue.shuffle() }
            i = 0
        }
        if i < 0 { i = queue.count - 1 }
        startTrack(at: i)
    }

    private func stop() {
        generation += 1
        player.stop()
        isPlaying = false
        current = nil
    }

    private func startTrack(at i: Int) {
        generation += 1
        let gen = generation
        index = i
        let track = queue[i]
        let url = folder.appendingPathComponent(track.fileName)
        guard let file = try? AVAudioFile(forReading: url) else { advance(by: 1); return }
        player.stop()
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.advance(by: 1)
            }
        }
        player.play()
        current = track
        isPlaying = true
    }

    // MARK: - Persistance

    private var indexURL: URL { folder.appendingPathComponent("library.json") }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: indexURL),
              let tracks = try? JSONDecoder().decode([Track].self, from: data) else { return }
        library = tracks.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
        queue = library
    }

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(library) { try? data.write(to: indexURL) }
    }
}
