import Combine
import Foundation

/// Journal interne visible dans l'app (Réglages → Diagnostic).
/// Sans Mac ni Xcode, c'est le seul moyen de voir ce qui se passe sur l'iPhone,
/// en particulier pendant la Phase 0 (connexion DJI).
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let tag: String
        let message: String
    }

    @Published private(set) var entries: [Entry] = []
    private let max = 500

    nonisolated static func log(_ tag: String, _ message: String) {
        Task { @MainActor in shared.append(Entry(tag: tag, message: message)) }
    }

    private func append(_ e: Entry) {
        entries.append(e)
        if entries.count > max { entries.removeFirst(entries.count - max) }
    }

    func clear() { entries = [] }

    /// Texte à copier-coller (dans une conversation avec Claude, par exemple).
    var exportText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return entries.map { "\(f.string(from: $0.date)) [\($0.tag)] \($0.message)" }.joined(separator: "\n")
    }
}

/// Infos de build, utiles au diagnostic sans Mac.
enum AppInfo {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "?" }
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
    static var hasDJIKey: Bool { !((Bundle.main.object(forInfoDictionaryKey: "DJISDKAppKey") as? String) ?? "").isEmpty }
    static var hasTwitchClientID: Bool { !((Bundle.main.object(forInfoDictionaryKey: "TwitchClientID") as? String) ?? "").isEmpty }
    static var summary: String {
        "Roamcast \(version) · bundle \(bundleID) · clé DJI \(hasDJIKey ? "oui" : "non") · Twitch \(hasTwitchClientID ? "oui" : "non")"
    }
}
