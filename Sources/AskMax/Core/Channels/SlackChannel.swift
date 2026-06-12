import Foundation

/// Slack bot via Socket Mode (WebSocket) — no public webhook required, which is
/// what makes it work for a local Mac app. Flow: open a socket URL with the
/// app-level token (xapp-…), receive event envelopes, ACK each, handle message
/// events, and reply with chat.postMessage using the bot token (xoxb-…).
@MainActor
final class SlackChannel {
    static let shared = SlackChannel()

    private var task: URLSessionWebSocketTask?
    private var running = false
    private var appToken = ""
    private var botToken = ""
    private var selfUserId = "" // bot's own user id, to ignore its own messages

    private init() {}

    func startIfEnabled() {
        let config = MaxConfig.load()
        guard config.slackEnabled,
              let app = SecretStore.secret(forKey: "slack-app"), !app.isEmpty,
              let bot = SecretStore.secret(forKey: "slack-bot"), !bot.isEmpty else {
            stop(); return
        }
        guard !running else { return }
        appToken = app
        botToken = bot
        running = true
        openSocket()
    }

    func stop() {
        running = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func openSocket() {
        guard running else { return }
        var request = URLRequest(url: URL(string: "https://slack.com/api/apps.connections.open")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                guard let data, let obj = JSON.decode(data),
                      obj["ok"] as? Bool == true, let urlStr = obj["url"] as? String,
                      let url = URL(string: urlStr) else {
                    ChannelLog.write("slack: apps.connections.open failed — check the app-level token")
                    self.retry()
                    return
                }
                let t = URLSession.shared.webSocketTask(with: url)
                self.task = t
                t.resume()
                self.receive()
            }
        }.resume()
    }

    private func retry() {
        guard running else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.running else { return }
            self.openSocket()
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.running else { return }
                switch result {
                case .failure:
                    self.task = nil
                    self.openSocket() // socket URLs are short-lived; reopen
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
        let type = obj["type"] as? String

        // Every events_api / interactive / slash envelope must be acked by id.
        if let envelopeId = obj["envelope_id"] as? String {
            send(["envelope_id": envelopeId])
        }

        switch type {
        case "hello", "disconnect":
            if type == "disconnect" { task = nil; openSocket() }
        case "events_api":
            guard let payload = obj["payload"] as? [String: Any],
                  let event = payload["event"] as? [String: Any] else { return }
            onEvent(event)
        default:
            break
        }
    }

    private func onEvent(_ event: [String: Any]) {
        guard event["type"] as? String == "message" else { return }
        // Ignore bot messages, edits, and subtype events (joins, etc.).
        if event["bot_id"] != nil { return }
        if event["subtype"] != nil { return }
        let userId = event["user"] as? String ?? ""
        let text = (event["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = event["channel"] as? String ?? ""
        guard !userId.isEmpty, !text.isEmpty, !channel.isEmpty else { return }

        let allow = MaxConfig.load().slackAllowlist
        guard allow.contains(userId) else {
            ChannelLog.write("slack: ignored message from user \(userId) — not in allowlist")
            return
        }

        let botToken = self.botToken
        ChannelRouter.shared.handle(key: "slack-\(channel)", text: text) { reply in
            Self.sendReply(channel: channel, text: reply, token: botToken)
        }
    }

    private func send(_ obj: [String: Any]) {
        task?.send(.string(JSON.encodeString(obj))) { _ in }
    }

    nonisolated static func sendReply(channel: String, text: String, token: String) {
        var request = URLRequest(url: URL(string: "https://slack.com/api/chat.postMessage")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = JSON.encode(["channel": channel, "text": String(text.prefix(3500))])
        URLSession.shared.dataTask(with: request).resume()
    }
}
