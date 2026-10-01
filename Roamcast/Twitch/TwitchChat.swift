import Foundation

/// Lecture du chat (CDC §12) via IRC-over-WebSocket.
/// Lecture seule en V1 ; migration possible vers EventSub (channel.chat.message) plus tard.
@MainActor
final class TwitchChat: ObservableObject {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let author: String
        let color: String?
        let text: String
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var connected = false

    private var task: URLSessionWebSocketTask?
    private var channel = ""
    private var token = ""
    private var nick = ""
    private let maxMessages = 150

    func connect(channel: String, login: String, token: String) {
        self.channel = channel.lowercased()
        self.nick = login.lowercased()
        self.token = token
        open()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    private func open() {
        let t = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
        task = t
        t.resume()
        send("CAP REQ :twitch.tv/tags twitch.tv/commands")
        send("PASS oauth:\(token)")
        send("NICK \(nick)")
        send("JOIN #\(channel)")
        receive()
    }

    private func send(_ line: String) { task?.send(.string(line)) { _ in } }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.string(let text)):
                    text.split(separator: "\r\n").forEach { self.handle(String($0)) }
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    // Réseau de rando : on retente sans bruit, le chat n'est pas critique.
                    self.connected = false
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if self.task != nil { self.open() }
                }
            }
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("PING") { send("PONG :tmi.twitch.tv"); return }
        if line.contains(" 366 ") { connected = true; return }   // fin de la liste JOIN
        guard let msg = Self.parsePrivmsg(line) else { return }
        messages.append(msg)
        if messages.count > maxMessages { messages.removeFirst(messages.count - maxMessages) }
    }

    /// `@badge-info=;color=#FF0000;display-name=Foo;... :foo!foo@foo.tmi.twitch.tv PRIVMSG #chan :salut`
    nonisolated static func parsePrivmsg(_ line: String) -> Message? {
        guard let privRange = line.range(of: " PRIVMSG #") else { return nil }
        var tags: [String: String] = [:]
        if line.hasPrefix("@"), let space = line.firstIndex(of: " ") {
            for pair in line[line.index(after: line.startIndex)..<space].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 { tags[String(kv[0])] = String(kv[1]) }
            }
        }
        let after = line[privRange.upperBound...]
        guard let colon = after.firstIndex(of: ":") else { return nil }
        let text = String(after[after.index(after: colon)...])
        var author = tags["display-name"].flatMap { $0.isEmpty ? nil : $0 }
        if author == nil, let bang = line.firstIndex(of: "!"),
           let start = line[..<bang].lastIndex(of: ":") {
            author = String(line[line.index(after: start)..<bang])
        }
        return Message(author: author ?? "?", color: tags["color"].flatMap { $0.isEmpty ? nil : $0 }, text: text)
    }
}
