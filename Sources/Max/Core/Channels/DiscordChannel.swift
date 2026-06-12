import Foundation

/// Discord bot via the Gateway (WebSocket). Connect → HELLO (heartbeat
/// interval) → send heartbeats + IDENTIFY → receive MESSAGE_CREATE dispatches →
/// reply over the REST API. Requires a bot token with the MESSAGE CONTENT
/// privileged intent enabled in the Discord developer portal.
@MainActor
final class DiscordChannel {
    static let shared = DiscordChannel()

    private var task: URLSessionWebSocketTask?
    private var heartbeatTimer: Timer?
    private var seq: Int?
    private var token = ""
    private var running = false

    private init() {}

    func startIfEnabled() {
        let config = MaxConfig.load()
        guard config.discordEnabled,
              let t = SecretStore.secret(forKey: "discord-bot"), !t.isEmpty else {
            stop(); return
        }
        guard !running else { return }
        token = t
        running = true
        connect()
    }

    func stop() {
        running = false
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connect() {
        guard running else { return }
        seq = nil
        let url = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
    }

    private func reconnect() {
        guard running else { return }
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.running else { return }
            self.connect()
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.running else { return }
                switch result {
                case .failure:
                    self.reconnect()
                case .success(let message):
                    switch message {
                    case .string(let s): self.handleFrame(s)
                    case .data(let d): if let s = String(data: d, encoding: .utf8) { self.handleFrame(s) }
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    private func handleFrame(_ raw: String) {
        guard let obj = JSON.decode(raw) else { return }
        if let s = obj["s"] as? Int { seq = s }
        switch obj["op"] as? Int {
        case 10: // HELLO
            let d = obj["d"] as? [String: Any]
            let interval = (d?["heartbeat_interval"] as? Double ?? 41250) / 1000.0
            startHeartbeat(interval)
            identify()
        case 0: // dispatch
            if obj["t"] as? String == "MESSAGE_CREATE", let d = obj["d"] as? [String: Any] {
                onMessage(d)
            }
        case 7, 9: // reconnect / invalid session
            reconnect()
        default:
            break
        }
    }

    private func startHeartbeat(_ interval: TimeInterval) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.send(["op": 1, "d": self.seq as Any])
            }
        }
    }

    private func identify() {
        // GUILD_MESSAGES (1<<9) | DIRECT_MESSAGES (1<<12) | MESSAGE_CONTENT (1<<15)
        let intents = (1 << 9) | (1 << 12) | (1 << 15)
        send(["op": 2, "d": [
            "token": token,
            "intents": intents,
            "properties": ["os": "macOS", "browser": "max", "device": "max"],
        ]])
    }

    private func onMessage(_ d: [String: Any]) {
        let author = d["author"] as? [String: Any] ?? [:]
        if author["bot"] as? Bool == true { return } // ignore bots, including self
        let authorId = author["id"] as? String ?? ""
        let authorName = author["username"] as? String ?? "?"
        let content = (d["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let channelId = d["channel_id"] as? String ?? ""
        guard !content.isEmpty, !channelId.isEmpty, !authorId.isEmpty else { return }

        let allow = MaxConfig.load().discordAllowlist
        guard allow.contains(authorId) else {
            // Log the sender so the user can find their ID and allowlist it.
            ChannelLog.write("discord: ignored message from \(authorName) (id \(authorId)) — not in allowlist")
            return
        }

        let token = self.token
        ChannelRouter.shared.handle(key: "discord-\(channelId)", text: content) { reply in
            Self.sendReply(channelId: channelId, text: reply, token: token)
        }
    }

    private func send(_ obj: [String: Any]) {
        task?.send(.string(JSON.encodeString(obj))) { _ in }
    }

    nonisolated static func sendReply(channelId: String, text: String, token: String) {
        var request = URLRequest(url: URL(string: "https://discord.com/api/v10/channels/\(channelId)/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = JSON.encode(["content": String(text.prefix(1900))])
        URLSession.shared.dataTask(with: request).resume()
    }
}

/// Shared lightweight log for channel diagnostics (sender IDs, errors).
enum ChannelLog {
    static func write(_ line: String) {
        let url = MaxPaths.root.appendingPathComponent("channels.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
