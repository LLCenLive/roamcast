import Foundation

/// OAuth Twitch via Device Code Grant Flow.
///
/// Pourquoi ce flow : une app iOS est un *client public* (impossible d'y cacher un client_secret).
/// Le Device Code Flow est prévu pour ça : pas de secret, refresh token fourni
/// (usage unique, expire après 30 jours d'inactivité → on stocke le nouveau à chaque refresh).
///
/// UX : l'app affiche un code + ouvre twitch.tv/activate dans Safari, l'utilisateur valide,
/// l'app récupère le token en sondant l'endpoint.
@MainActor
final class TwitchAuth: ObservableObject {
    struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    private struct ErrorResponse: Decodable { let message: String? }

    enum AuthError: Error { case expired, denied, http(Int, String) }

    /// Portées nécessaires (CDC §12).
    static let scopes = [
        "channel:manage:broadcast",   // titre, catégorie, langue, tags
        "channel:read:stream_key",    // récupération du stream key
        "chat:read",                  // lecture du chat (IRC)
    ]

    let clientID: String
    @Published private(set) var isSignedIn = false
    @Published var pendingCode: DeviceCode?

    private var accessToken: String? { didSet { isSignedIn = accessToken != nil } }
    private var expiresAt: Date = .distantPast

    init(clientID: String) {
        self.clientID = clientID
        accessToken = Keychain.get("twitch.access")
        if let ts = Keychain.get("twitch.expires"), let t = TimeInterval(ts) { expiresAt = Date(timeIntervalSince1970: t) }
    }

    // MARK: - Connexion

    func startDeviceFlow() async throws -> DeviceCode {
        let code: DeviceCode = try await post("https://id.twitch.tv/oauth2/device", [
            "client_id": clientID,
            "scopes": Self.scopes.joined(separator: " "),
        ])
        pendingCode = code
        return code
    }

    /// Sonde jusqu'à validation par l'utilisateur (ou expiration).
    func waitForAuthorization(_ code: DeviceCode) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
        var interval = max(code.interval, 1)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            do {
                let token: TokenResponse = try await post("https://id.twitch.tv/oauth2/token", [
                    "client_id": clientID,
                    "scopes": Self.scopes.joined(separator: " "),
                    "device_code": code.device_code,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
                store(token)
                pendingCode = nil
                return
            } catch AuthError.http(_, let msg) where msg.contains("authorization_pending") {
                continue
            } catch AuthError.http(_, let msg) where msg.contains("slow_down") {
                interval += 5
            } catch AuthError.http(_, let msg) where msg.contains("access_denied") {
                pendingCode = nil
                throw AuthError.denied
            }
        }
        pendingCode = nil
        throw AuthError.expired
    }

    func signOut() {
        ["twitch.access", "twitch.refresh", "twitch.expires"].forEach(Keychain.delete)
        accessToken = nil
    }

    // MARK: - Token valide

    /// Renvoie un token valide, en le rafraîchissant si besoin.
    func validToken() async throws -> String {
        if let t = accessToken, Date() < expiresAt.addingTimeInterval(-120) { return t }
        guard let refresh = Keychain.get("twitch.refresh") else { throw AuthError.expired }
        let token: TokenResponse = try await post("https://id.twitch.tv/oauth2/token", [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ])
        store(token)
        return token.access_token
    }

    private func store(_ t: TokenResponse) {
        Keychain.set(t.access_token, for: "twitch.access")
        // Refresh token à usage unique : TOUJOURS remplacer l'ancien.
        if let r = t.refresh_token { Keychain.set(r, for: "twitch.refresh") }
        expiresAt = Date().addingTimeInterval(TimeInterval(t.expires_in ?? 3600))
        Keychain.set(String(expiresAt.timeIntervalSince1970), for: "twitch.expires")
        accessToken = t.access_token
    }

    private func post<T: Decodable>(_ url: String, _ form: [String: String]) async throws -> T {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message
                ?? String(data: data, encoding: .utf8) ?? ""
            throw AuthError.http(status, msg)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
