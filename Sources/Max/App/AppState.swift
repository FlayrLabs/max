import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

/// A file or image the user dropped on the pill, pending the next message.
struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    enum Kind: Equatable {
        case image(ImagePayload)
        case file(path: String)
    }
    let kind: Kind
    let name: String
    var isImage: Bool { if case .image = kind { return true }; return false }
}

// MARK: - UI message model

struct ChatMessageVM: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case tool(name: String, isError: Bool)
        case error
    }
    let id = UUID()
    var kind: Kind
    var text: String
    var isStreaming: Bool = false
}

/// Holds ONLY the in-flight assistant text. Kept separate from AppState so
/// streaming updates re-render just the live bubble — not the whole conversation
/// list. The view reveals `fullText` smoothly via a display-synced TimelineView;
/// the network handler just appends raw chunks here as they arrive.
@MainActor
final class StreamBuffer: ObservableObject {
    @Published private(set) var fullText = ""
    /// Character count, maintained incrementally (String.count is O(n)).
    private(set) var fullCount = 0

    func reset() { fullText = ""; fullCount = 0 }
    func append(_ piece: String) {
        fullText += piece
        fullCount += piece.count
    }
}

// MARK: - App state (flayr-studio's chat shell state machine, native)
// closed_idle → open → closed_working → closed_idle

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var config: MaxConfig
    @Published var messages: [ChatMessageVM] = []
    @Published var chatOpen = false
    @Published var isWorking = false          // a chat turn is in flight
    @Published var loopActivity = false       // a background loop is running
    @Published var draft = ""
    @Published var pendingAttachments: [PendingAttachment] = []

    /// Wired by the AppDelegate to show/hide the chat panel.
    var onChatOpenChanged: ((Bool) -> Void)?
    /// Wired by the AppDelegate to re-register the global summon shortcut.
    var onHotKeyChanged: (() -> Void)?

    func applyHotKey() { onHotKeyChanged?() }

    /// True while an assistant message is actively streaming. Toggles once at
    /// the start/end of a turn (cheap), so ChatView can show/hide the live
    /// bubble without observing the per-frame text churn.
    @Published private(set) var streaming = false
    /// Network turn finished — the live bubble should finish revealing its tail
    /// then commit to history.
    @Published private(set) var awaitingFinish = false
    @Published private(set) var conversations: [ConversationMeta] = []
    @Published private(set) var currentConversationId: String = ""

    /// The live assistant text, on its own observable object (see StreamBuffer).
    let streamBuffer = StreamBuffer()

    private var session: ChatSession
    private var currentTask: Task<Void, Never>?

    private init() {
        self.config = MaxConfig.load()
        MaxPaths.ensure()
        // Reopen the most recent conversation, falling back to a fresh one.
        let startId = Conversations.mostRecentId() ?? Conversations.newId()
        self.session = ChatSession(id: startId)
        self.currentConversationId = startId
        replayTranscript()
        refreshConversations()
        LoopScheduler.shared.onActivityChanged = { [weak self] active in
            self?.loopActivity = active
        }
    }

    var needsOnboarding: Bool {
        !config.onboarded ||
        (config.provider.needsAPIKey && (SecretStore.apiKey(for: config.provider) ?? "").isEmpty)
    }

    // MARK: Conversations

    func refreshConversations() {
        conversations = Conversations.list()
    }

    func newConversation() {
        stop()
        session = ChatSession(id: Conversations.newId())
        currentConversationId = session.id
        messages = []
        refreshConversations()
    }

    func switchConversation(to id: String) {
        guard id != currentConversationId else { return }
        stop()
        session = ChatSession(id: id)
        currentConversationId = id
        messages = []
        replayTranscript()
        refreshConversations()
    }

    func deleteCurrentConversation() {
        stop()
        Conversations.delete(id: session.id)
        let next = Conversations.mostRecentId()
        session = ChatSession(id: next ?? Conversations.newId())
        currentConversationId = session.id
        messages = []
        replayTranscript()
        refreshConversations()
    }

    func saveConfig() {
        config.save()
        objectWillChange.send()
    }

    func setPaused(_ paused: Bool) {
        config.paused = paused
        saveConfig()
        if paused {
            stop() // cancel any in-flight desk run
        }
    }

    func acknowledgeRisk() {
        config.acknowledgedRisk = true
        saveConfig()
    }

    /// Chat typography honoring the user's font settings. `delta` offsets the
    /// base size (e.g. -2.5 for tool chips).
    func chatFont(_ delta: CGFloat = 0, weight: Font.Weight = .regular) -> Font {
        let size = max(9, CGFloat(config.fontSize) + delta)
        if config.fontFamily.isEmpty {
            return .system(size: size, weight: weight)
        }
        return .custom(config.fontFamily, size: size).weight(weight)
    }

    // MARK: Chat shell

    func openChat() {
        guard !chatOpen else { return }
        chatOpen = true
        onChatOpenChanged?(true)
    }

    func closeChat() {
        guard chatOpen else { return }
        chatOpen = false
        onChatOpenChanged?(false)
    }

    func toggleChat() {
        chatOpen ? closeChat() : openChat()
    }

    func submitDraft() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !(typed.isEmpty && attachments.isEmpty), !isWorking else { return }

        let images = attachments.compactMap { a -> ImagePayload? in
            if case .image(let p) = a.kind { return p }; return nil
        }
        let files = attachments.compactMap { a -> String? in
            if case .file(let path) = a.kind { return path }; return nil
        }

        var text = typed
        if !files.isEmpty {
            text += (text.isEmpty ? "" : "\n\n")
                + "Attached files (use read_file or exec to inspect):\n"
                + files.map { "- \($0)" }.joined(separator: "\n")
        }
        if text.isEmpty && !images.isEmpty { text = "(see attached image)" }

        draft = ""
        pendingAttachments = []
        openChat()
        send(text, images: images)
    }

    // MARK: Drag & drop attachments

    /// Handle items dropped on the pill (file URLs from Finder, or raw image data).
    func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in self.addAttachment(url: url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let payload = SeeScreenTool.jpegPayload(fromData: data, maxPixels: 1500, quality: 0.72) else { return }
                    Task { @MainActor in
                        self.pendingAttachments.append(.init(kind: .image(payload), name: "image"))
                    }
                }
            }
        }
    }

    private func addAttachment(url: URL) {
        let name = url.lastPathComponent
        let isImage = (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false
        if isImage, let payload = SeeScreenTool.jpegPayload(from: url, maxPixels: 1500, quality: 0.72) {
            pendingAttachments.append(.init(kind: .image(payload), name: name))
        } else {
            pendingAttachments.append(.init(kind: .file(path: url.path), name: name))
        }
    }

    func removeAttachment(_ id: PendingAttachment.ID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// A message arriving from a channel (iMessage). Joins the current
    /// conversation so desk and phone share one session; `onFinal` receives
    /// Max's final text for the reply.
    func sendRemote(_ text: String, onFinal: @escaping (String) -> Void) {
        guard !isWorking else {
            onFinal("I'm mid-task right now — text me again in a minute.")
            return
        }
        send(text, onFinal: onFinal)
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        isWorking = false
        finishLiveBubble()
    }

    /// Kept for old call sites — "clear" now means "start a new conversation"
    /// (history is preserved on disk and reachable from the conversation menu).
    func clearConversation() { newConversation() }

    private func send(_ text: String, images: [ImagePayload] = [], onFinal: ((String) -> Void)? = nil) {
        // Defensive: commit any leftover live bubble before starting a new turn
        // so a previous reply can never bleed into this one.
        finishLiveBubble()
        let shown = images.isEmpty ? text : (text + (text.isEmpty ? "" : "  ") + "🖼️×\(images.count)")
        messages.append(ChatMessageVM(kind: .user, text: shown))
        isWorking = true
        let config = self.config

        currentTask = Task { [weak self] in
            guard let self else { return }
            var finalText = ""
            for await event in AgentLoop.run(session: self.session, userText: text, config: config, images: images) {
                if Task.isCancelled { break }
                if case .turnEnded(let t) = event { finalText = t }
                if case .failed(let message) = event { finalText = "Something went wrong: \(message)" }
                self.handle(event)
            }
            self.refreshConversations()
            onFinal?(finalText)
            // Keep the turn "busy" until the live bubble finishes revealing and
            // commits — otherwise a new message could interleave with the still
            // -uncommitted stream (splits/reorders the reply). finishLiveBubble
            // clears isWorking when it commits the end-of-turn bubble.
            if self.streaming {
                self.awaitingFinish = true
            } else {
                self.isWorking = false
            }
        }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .textDelta(let piece):
            if !streaming { streaming = true; streamBuffer.reset() }
            streamBuffer.append(piece)

        case .toolStarted(let name, let summary):
            finishLiveBubble()
            messages.append(ChatMessageVM(kind: .tool(name: name, isError: false), text: summary))

        case .toolFinished(let name, _, let isError):
            if isError,
               let i = messages.lastIndex(where: {
                   if case .tool(let n, _) = $0.kind { return n == name }
                   return false
               }) {
                if case .tool(let n, _) = messages[i].kind {
                    messages[i].kind = .tool(name: n, isError: true)
                }
            }

        case .turnEnded:
            break // finishLiveBubble handles the commit once revealing catches up

        case .failed(let message):
            finishLiveBubble()
            messages.append(ChatMessageVM(kind: .error, text: message))
        }
    }

    /// Move the live text into committed history as a normal (markdown-rendered,
    /// glass) assistant row, then clear the live buffer. Called by the live
    /// bubble once it has finished revealing, or immediately at tool/stop
    /// boundaries.
    func finishLiveBubble() {
        guard streaming else { return }
        // awaitingFinish marks the end-of-turn finish (vs a mid-turn tool
        // boundary); only then is the whole turn actually done.
        let endsTurn = awaitingFinish
        let text = streamBuffer.fullText
        if !text.isEmpty {
            messages.append(ChatMessageVM(kind: .assistant, text: text, isStreaming: false))
        }
        streamBuffer.reset()
        streaming = false
        awaitingFinish = false
        if endsTurn { isWorking = false }
    }

    private func replayTranscript() {
        for turn in session.turns.suffix(60) {
            switch turn.role {
            case .user:
                for case .text(let t) in turn.blocks where !t.isEmpty {
                    // Skip synthetic loop prompts and tool-result turns.
                    messages.append(ChatMessageVM(kind: .user, text: t))
                }
            case .assistant:
                for block in turn.blocks {
                    switch block {
                    case .text(let t) where !t.isEmpty:
                        messages.append(ChatMessageVM(kind: .assistant, text: t))
                    case .toolUse(_, let name, _):
                        messages.append(ChatMessageVM(kind: .tool(name: name, isError: false), text: name))
                    default:
                        break
                    }
                }
            }
        }
    }
}
