import Foundation
import SQLite3

/// iMessage channel — OpenClaw's channel model, native:
/// poll ~/Library/Messages/chat.db for new texts from allowlisted handles,
/// run them through the agent, reply via Messages.app.
///
/// Self-chat safe: when you text your own iCloud from your phone, both your
/// command and Max's reply land in chat.db as `is_from_me = 1`, so we dedupe
/// against the texts Max recently sent to avoid reply loops.
@MainActor
final class IMessageBridge: ObservableObject {
    static let shared = IMessageBridge()

    @Published private(set) var status: String = "off"
    @Published private(set) var lastError: String?

    private var timer: Timer?
    private var lastRowId: Int64 = 0
    private var recentlySent: [(text: String, at: Date)] = []
    private var queue: [(handle: String, text: String)] = []
    private var ownHandles: Set<String> = [] // this Mac's own iMessage addresses (normalized)
    private var processing = false
    private var repliesThisMinute = 0
    private var minuteWindowStart = Date()

    private var stateFile: URL { MaxPaths.root.appendingPathComponent("imessage-state.json") }
    private nonisolated static let dbPath = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath

    private init() {}

    /// Prefix on every reply Max sends. In a note-to-self thread both your
    /// command and Max's reply are "from you" (same side), so this label is the
    /// only way to tell them apart — and it doubles as a loop guard.
    static let replyMarker = "🤖 "

    // MARK: Lifecycle

    func startIfEnabled() {
        let config = MaxConfig.load()
        guard config.imessageEnabled else {
            stop()
            return
        }
        guard timer == nil else { return }

        loadState()
        if lastRowId == 0 {
            // First run: skip history, only react to messages from now on.
            lastRowId = Self.maxRowId() ?? 0
            saveState()
        }
        status = "listening"
        lastError = nil
        // Auto-detect this Mac's own iMessage handles (number + Apple-ID emails)
        // so the user never has to allowlist their own addresses.
        Task.detached(priority: .utility) {
            let handles = Self.detectOwnHandles()
            await MainActor.run { self.ownHandles = handles }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Run on common modes so it keeps polling during menu/UI interaction.
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        status = "off"
    }

    var hasFullDiskAccess: Bool {
        Self.maxRowId() != nil
    }

    // MARK: Poll loop

    private func tick() {
        let config = MaxConfig.load()
        guard config.imessageEnabled else { stop(); return }
        let allowlist = config.imessageAllowlist
        let selfHandle = config.imessageSelfHandle.trimmingCharacters(in: .whitespaces)
        guard !allowlist.isEmpty || !selfHandle.isEmpty else {
            status = "set your iMessage handle in Settings"
            return
        }

        let after = lastRowId
        Task.detached(priority: .utility) {
            guard let result = Self.fetchMessages(after: after) else {
                Self.debugLog("FETCH FAILED (no Full Disk Access?) after=\(after)")
                await MainActor.run {
                    self.lastError = "Can't read the Messages database — grant Max Full Disk Access."
                    self.status = "blocked"
                }
                return
            }
            if !result.messages.isEmpty {
                Self.debugLog("fetched \(result.messages.count) new message(s) after row \(after); " +
                    "selfHandle='\(selfHandle)' allowlist=\(allowlist)")
            }
            await MainActor.run {
                self.lastError = nil
                self.status = "listening"
                self.ingest(result.messages, maxRowId: result.maxRowId,
                            allowlist: allowlist, selfHandle: selfHandle)
            }
        }
    }

    private func ingest(_ messages: [IncomingMessage], maxRowId: Int64,
                        allowlist: [String], selfHandle: String) {
        if maxRowId > lastRowId {
            lastRowId = maxRowId
            saveState()
        }
        recentlySent.removeAll { $0.at.timeIntervalSinceNow < -300 }

        // One normalized set of trusted handles: this Mac's own addresses
        // (auto-detected) + the configured self-handle + the manual allowlist.
        // A message is authorized if it involves any of these — whether it
        // arrives as a note-to-self (is_from_me) or from one of your other
        // Apple IDs / allowed people (not from-me).
        var trusted = ownHandles
        for h in (allowlist + [selfHandle]) where !h.isEmpty {
            trusted.insert(Self.normalize(h))
        }

        for message in messages {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let chatNorm = Self.normalize(message.chatIdentifier)
            let senderNorm = Self.normalize(message.handle)

            var decision = ""
            defer {
                Self.debugLog("row=\(message.rowId) fromMe=\(message.isFromMe) " +
                    "handle='\(message.handle)' chat='\(message.chatIdentifier)' " +
                    "textLen=\(text.count) text='\(text.prefix(40))' -> \(decision)")
            }

            guard !text.isEmpty else { decision = "skip: empty text"; continue }
            // Max's own replies carry the marker — never react to them.
            if text.hasPrefix(Self.replyMarker) { decision = "skip: own reply (marker)"; continue }
            if recentlySent.contains(where: { $0.text == text }) { decision = "skip: own reply"; continue }

            if message.isFromMe {
                // You texting yourself: the conversation must be with one of your
                // own trusted handles.
                guard trusted.contains(chatNorm) else { decision = "skip: from-me, untrusted thread"; continue }
                let replyTo = message.chatIdentifier.isEmpty ? selfHandle : message.chatIdentifier
                queue.append((handle: replyTo, text: text))
                decision = "QUEUED (self) replyTo=\(replyTo)"
            } else {
                // From another identity: the sender must be trusted.
                guard !message.handle.isEmpty, trusted.contains(senderNorm) else {
                    decision = "skip: sender not trusted"; continue
                }
                queue.append((handle: message.handle, text: text))
                decision = "QUEUED (trusted sender)"
            }
        }
        processNext()
    }

    nonisolated static func debugLog(_ line: String) {
        let url = MaxPaths.root.appendingPathComponent("imessage-debug.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func processNext() {
        guard !processing, !queue.isEmpty else { return }
        guard !AppState.shared.isWorking else { return } // retry on next tick

        // Rate limit: max 6 agent runs per minute from iMessage.
        if Date().timeIntervalSince(minuteWindowStart) > 60 {
            minuteWindowStart = Date()
            repliesThisMinute = 0
        }
        guard repliesThisMinute < 6 else { return }
        repliesThisMinute += 1

        let item = queue.removeFirst()
        processing = true
        status = "handling a text"

        AppState.shared.sendRemote(item.text) { [weak self] reply in
            guard let self else { return }
            let body = reply.isEmpty ? "Done." : String(reply.prefix(1800))
            let outgoing = Self.replyMarker + body
            self.recentlySent.append((text: outgoing, at: Date()))
            Self.sendMessage(outgoing, to: item.handle)
            self.processing = false
            self.status = "listening"
            self.processNext()
        }
    }

    // MARK: Sending via Messages.app

    static func sendMessage(_ text: String, to handle: String) {
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedHandle = handle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant "\(escapedHandle)" of targetService
            send "\(escapedText)" to targetBuddy
        end tell
        """
        Task.detached(priority: .utility) {
            let shellEscaped = script.replacingOccurrences(of: "'", with: "'\\''")
            _ = await ExecTool.runShell("osascript -e '\(shellEscaped)'", timeout: 30)
        }
    }

    // MARK: Allowlist matching

    static func matches(handle: String, allowlist: [String]) -> Bool {
        let normalizedHandle = normalize(handle)
        return allowlist.contains { normalize($0) == normalizedHandle }
    }

    nonisolated private static func normalize(_ raw: String) -> String {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.contains("@") { return lower }
        // Phone: compare by last 10 digits so +1 prefixes etc. don't matter.
        let digits = lower.filter(\.isNumber)
        return digits.count >= 10 ? String(digits.suffix(10)) : digits
    }

    // MARK: chat.db reading

    struct IncomingMessage {
        let rowId: Int64
        let text: String
        let isFromMe: Bool
        let handle: String          // the sender (empty for your own / note-to-self)
        let chatIdentifier: String  // the conversation's handle (your own for note-to-self)
    }

    /// This Mac's own iMessage send/receive handles, read from chat.account_login
    /// ("iMessage;-;+1555…" / "iMessage;-;you@icloud.com"). Returns normalized
    /// handles so the user never has to allowlist their own addresses.
    nonisolated static func detectOwnHandles() -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, db != nil else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT DISTINCT account_login FROM chat WHERE account_login IS NOT NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var handles: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let login = String(cString: c) // e.g. "iMessage;-;+16109054171"
            if let last = login.split(separator: ";").last {
                let h = String(last)
                if h.contains("@") || h.contains(where: \.isNumber) {
                    handles.insert(normalize(h))
                }
            }
        }
        return handles
    }

    nonisolated static func maxRowId() -> Int64? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, db != nil else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(ROWID),0) FROM message", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    nonisolated static func fetchMessages(after rowId: Int64) -> (messages: [IncomingMessage], maxRowId: Int64)? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, db != nil else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, COALESCE(h.id, ''),
               COALESCE(c.chat_identifier, '')
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.ROWID > ?
        ORDER BY m.ROWID ASC
        LIMIT 50
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowId)

        var messages: [IncomingMessage] = []
        var maxId = rowId
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            maxId = max(maxId, id)

            var text = ""
            if let cText = sqlite3_column_text(stmt, 1) {
                text = String(cString: cText)
            }
            if text.isEmpty, let blob = sqlite3_column_blob(stmt, 2) {
                let length = Int(sqlite3_column_bytes(stmt, 2))
                let data = Data(bytes: blob, count: length)
                text = decodeAttributedBody(data) ?? ""
            }

            let isFromMe = sqlite3_column_int(stmt, 3) == 1
            var handle = ""
            if let cHandle = sqlite3_column_text(stmt, 4) {
                handle = String(cString: cHandle)
            }
            var chatIdentifier = ""
            if let cChat = sqlite3_column_text(stmt, 5) {
                chatIdentifier = String(cString: cChat)
            }
            messages.append(IncomingMessage(
                rowId: id, text: text, isFromMe: isFromMe,
                handle: handle, chatIdentifier: chatIdentifier
            ))
        }
        return (messages, maxId)
    }

    /// Modern macOS often leaves `text` NULL and stores the body in a
    /// typedstream blob. This extracts the NSString payload heuristically.
    nonisolated static func decodeAttributedBody(_ data: Data) -> String? {
        guard let marker = data.range(of: Data("NSString".utf8)) else { return nil }
        var i = marker.upperBound + 5 // skip class-info bytes to the '+' tag
        guard i < data.count else { return nil }

        var length = 0
        let first = data[i]
        if first == 0x81 { // 16-bit little-endian length follows
            guard i + 2 < data.count else { return nil }
            length = Int(data[i + 1]) | (Int(data[i + 2]) << 8)
            i += 3
        } else {
            length = Int(first)
            i += 1
        }
        guard length > 0, i + length <= data.count else { return nil }
        return String(data: data[i ..< i + length], encoding: .utf8)
    }

    // MARK: State

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFile),
              let obj = JSON.decode(data),
              let saved = obj["lastRowId"] as? Int else { return }
        lastRowId = Int64(saved)
    }

    private func saveState() {
        MaxPaths.ensure()
        try? JSON.encode(["lastRowId": Int(lastRowId)]).write(to: stateFile, options: .atomic)
    }
}
