import Foundation

/// API Helix (CDC §4, §12).
/// Totalement indépendante du moteur RTMP : modifier le titre ne touche jamais la vidéo.
@MainActor
final class TwitchAPI {
    struct User: Decodable { let id: String; let login: String; let display_name: String }
    struct Stream: Decodable { let viewer_count: Int; let started_at: String }
    struct Channel: Decodable {
        let title: String
        let game_id: String
        let game_name: String
        let broadcaster_language: String
        let tags: [String]
    }

    /// Mise à jour partielle : seuls les champs non nil sont envoyés.
    struct ChannelUpdate: Encodable {
        var title: String?
        var game_id: String?
        var broadcaster_language: String?
        var tags: [String]?
    }

    enum APIError: Error { case http(Int, String), empty }

    private let auth: TwitchAuth
    private(set) var me: User?
    private let base = "https://api.twitch.tv/helix"

    init(auth: TwitchAuth) { self.auth = auth }

    /// Ingest par défaut : Twitch route automatiquement vers le serveur le plus proche.
    static let defaultIngest = "rtmp://live.twitch.tv/app"

    func loadMe() async throws -> User {
        let users: [User] = try await get("/users")
        guard let u = users.first else { throw APIError.empty }
        me = u
        return u
    }

    func streamKey() async throws -> String {
        struct Key: Decodable { let stream_key: String }
        let id = try await broadcasterID()
        let keys: [Key] = try await get("/streams/key", ["broadcaster_id": id])
        guard let k = keys.first?.stream_key else { throw APIError.empty }
        return k
    }

    func channel() async throws -> Channel {
        let id = try await broadcasterID()
        let list: [Channel] = try await get("/channels", ["broadcaster_id": id])
        guard let c = list.first else { throw APIError.empty }
        return c
    }

    /// Édition à chaud (CDC §4.3). Aucun lien avec la connexion RTMP.
    func updateChannel(_ update: ChannelUpdate) async throws {
        let id = try await broadcasterID()
        _ = try await request("PATCH", "/channels", ["broadcaster_id": id], body: try JSONEncoder().encode(update))
    }

    func searchCategories(_ query: String) async throws -> [TwitchCategory] {
        struct Cat: Decodable { let id: String; let name: String }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let cats: [Cat] = try await get("/search/categories", ["query": query, "first": "20"])
        return cats.map { TwitchCategory(id: $0.id, name: $0.name) }
    }

    /// nil = pas (encore) en ligne côté Twitch.
    func liveStream() async throws -> Stream? {
        let id = try await broadcasterID()
        let streams: [Stream] = try await get("/streams", ["user_id": id])
        return streams.first
    }

    // MARK: - HTTP

    private func broadcasterID() async throws -> String {
        if let me { return me.id }
        return try await loadMe().id
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> [T] {
        let data = try await request("GET", path, query, body: nil)
        return try JSONDecoder().decode(HelixEnvelope<T>.self, from: data).data
    }

    private func request(_ method: String, _ path: String, _ query: [String: String], body: Data?) async throws -> Data {
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.validToken())", forHTTPHeaderField: "Authorization")
        req.setValue(auth.clientID, forHTTPHeaderField: "Client-Id")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

/// Toutes les réponses Helix ont la forme `{ "data": [...] }`.
private struct HelixEnvelope<T: Decodable>: Decodable { let data: [T] }
