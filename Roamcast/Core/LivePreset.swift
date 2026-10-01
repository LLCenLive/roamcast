import Foundation

enum PublicLocationMode: String, Codable, CaseIterable, Identifiable {
    case zone          // « Lac du Salagou » – défaut recommandé
    case approximate   // position arrondie
    case hidden        // rien sur Twitch
    var id: String { rawValue }
    var label: String {
        switch self {
        case .zone: return "Zone"
        case .approximate: return "Approximation"
        case .hidden: return "Masquée"
        }
    }
}

enum QualityProfile: String, Codable, CaseIterable, Identifiable {
    case eco, normal, high
    var id: String { rawValue }

    var label: String {
        switch self {
        case .eco: return "Éco · 720p30"
        case .normal: return "Normal · 1080p30"
        case .high: return "Haute · 1080p30"
        }
    }
    var width: Int { self == .eco ? 1280 : 1920 }
    var height: Int { self == .eco ? 720 : 1080 }
    var fps: Int { 30 }
    /// Débits en bit/s (CDC §11).
    var maxBitrate: Int {
        switch self {
        case .eco: return 3_000_000
        case .normal: return 5_000_000
        case .high: return 6_000_000
        }
    }
    var startBitrate: Int {
        switch self {
        case .eco: return 2_500_000
        case .normal: return 4_500_000
        case .high: return 5_500_000
        }
    }
    /// Plancher de dégradation : on préfère une image moche à une coupure.
    var minBitrate: Int { 800_000 }
}

struct DuckingSettings: Codable, Equatable {
    var enabled = true
    var reductionDB: Float = -12          // -6 / -12 / -18
    var releaseSeconds: Float = 1.2       // vitesse de remontée
}

struct TwitchCategory: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
}

struct LivePreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var title: String
    var category: TwitchCategory?
    var language: String = "fr"
    var tags: [String]
    var locationMode: PublicLocationMode = .zone
    var quality: QualityProfile = .normal
    var adaptiveBitrate = true
    var ducking = DuckingSettings()

    /// Presets par défaut (CDC §4.2). Les catégories sont résolues via l'API au premier usage,
    /// l'ID « IRL » (509672) est stable côté Twitch mais on le revalide à la connexion.
    static let defaults: [LivePreset] = [
        LivePreset(name: "Balade + Drone", title: "Balade & vol drone en direct",
                   category: TwitchCategory(id: "509672", name: "IRL"),
                   tags: ["Français", "Outdoor", "Drone"]),
        LivePreset(name: "Balade", title: "Balade en direct",
                   category: TwitchCategory(id: "509672", name: "IRL"),
                   tags: ["Français", "Outdoor"]),
        LivePreset(name: "Drone", title: "Vol drone en direct",
                   category: TwitchCategory(id: "509672", name: "IRL"),
                   tags: ["Français", "Drone", "Aviation"]),
    ]
}

/// Règles Twitch sur les tags : 10 max, 25 caractères max, alphanumérique sans espace.
enum TwitchTagRules {
    static let maxCount = 10
    static let maxLength = 25

    static func sanitize(_ raw: String) -> String? {
        let cleaned = raw.filter { $0.isLetter || $0.isNumber }
        guard !cleaned.isEmpty, cleaned.count <= maxLength else { return nil }
        return cleaned
    }

    static func add(_ raw: String, to tags: [String]) -> [String] {
        guard tags.count < maxCount, let tag = sanitize(raw),
              !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return tags }
        return tags + [tag]
    }
}

final class PresetStore: ObservableObject {
    @Published var presets: [LivePreset] { didSet { save() } }
    private let key = "roamcast.presets.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([LivePreset].self, from: data), !decoded.isEmpty {
            presets = decoded
        } else {
            presets = LivePreset.defaults
        }
    }

    func upsert(_ preset: LivePreset) {
        if let i = presets.firstIndex(where: { $0.id == preset.id }) { presets[i] = preset }
        else { presets.append(preset) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: key) }
    }
}
