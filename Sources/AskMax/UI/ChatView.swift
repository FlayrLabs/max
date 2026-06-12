import SwiftUI

/// The chat surface that appears above the pill — same glass family as the pill,
/// 220ms scale/fade on open/close, conversation persists across open/close.
struct ChatView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(
            .regular.tint(Color.black.opacity(0.22)),
            in: .rect(cornerRadius: 20, style: .continuous)
        )
        .ignoresSafeArea()
        .onExitCommand { state.closeChat() }
    }

    private var header: some View {
        ZStack {
            // Centered title (duck + Max), independent of the side controls.
            HStack(spacing: 8) {
                DuckIcon(size: 18)
                Text("Max").font(.system(size: 14, weight: .bold))
            }

            // Side controls: loop status on the left, conversations on the right.
            HStack(spacing: 8) {
                if state.loopActivity {
                    Label("loop", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("New Conversation") { state.newConversation() }
                    if !state.conversations.isEmpty {
                        Divider()
                        ForEach(state.conversations) { convo in
                            Button {
                                state.switchConversation(to: convo.id)
                            } label: {
                                if convo.id == state.currentConversationId {
                                    Label(convo.title, systemImage: "checkmark")
                                } else {
                                    Text(convo.title)
                                }
                            }
                        }
                        Divider()
                        Button("Delete Current Conversation", role: .destructive) {
                            state.deleteCurrentConversation()
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .fixedSize()
                .help("Conversations")
            }
            .padding(.leading, 92) // clear the traffic-light buttons
            .padding(.trailing, 14)
        }
        .frame(height: 46, alignment: .center)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if state.messages.isEmpty && !state.streaming {
                        emptyState
                    }
                    ForEach(state.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    // Live, in-flight assistant text — isolated so it re-renders
                    // alone (no glass blur) while streaming. It follows the
                    // bottom itself (throttled) as text reveals.
                    if state.streaming {
                        LiveBubble(
                            buffer: state.streamBuffer,
                            font: state.chatFont(),
                            finishing: state.awaitingFinish,
                            proxy: proxy,
                            onFinishedReveal: { state.finishLiveBubble() }
                        )
                    } else if state.isWorking {
                        // Thinking, or working between tool calls.
                        TypingIndicator()
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            // Explicit jumps for discrete events the anchor doesn't cover:
            // each new message, streaming start/stop, and reopening the chat.
            .onChange(of: state.messages.count) { scrollToBottom(proxy) }
            .onChange(of: state.streaming) { scrollToBottom(proxy) }
            .onChange(of: state.isWorking) { scrollToBottom(proxy) }
            .onChange(of: state.chatOpen) { if state.chatOpen { scrollToBottom(proxy) } }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    static let bottomAnchor = "chat-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(ChatView.bottomAnchor, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hey\(state.config.userName.isEmpty ? "" : " \(state.config.userName)") — I'm Max.")
                .font(.system(size: 16, weight: .bold))
            Text("I can run things on this Mac, automate apps, and set up loops that work for you on a schedule. Try:")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("• \"How much free disk space do I have?\"")
                Text("• \"Open my last screenshot\"")
                Text("• \"Every morning at 8, summarize my calendar for today\"")
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }
}

/// The in-flight assistant message. Reveals `buffer.fullText` smoothly using a
/// display-synced TimelineView (vsync-aligned, unlike a Timer) with an easing
/// reveal that speeds up to absorb network bursts. Uses a cheap solid
/// background — recomputing a glass blur every frame is what stuttered.
private struct LiveBubble: View {
    @ObservedObject var buffer: StreamBuffer
    let font: Font
    let finishing: Bool
    let proxy: ScrollViewProxy
    let onFinishedReveal: () -> Void

    /// Reference-type so we can advance it from inside the TimelineView closure
    /// without tripping SwiftUI's "modifying state during update" guard.
    final class Clock { var revealed = 0.0; var last: Date? }
    @State private var clock = Clock()
    @State private var lastScrolled = 0

    var body: some View {
        TimelineView(.animation) { context in
            let _ = advance(to: context.date, target: Double(buffer.fullCount))
            let count = min(buffer.fullCount, Int(clock.revealed.rounded()))
            let shown = String(buffer.fullText.prefix(count))

            HStack {
                Text(verbatim: shown + "▍")
                    .font(font)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                Spacer(minLength: 80)
            }
            .onChange(of: count) { _, newCount in
                // Follow the bottom, throttled (~every 12 chars) so we don't
                // scroll every frame.
                if newCount - lastScrolled >= 12 || newCount >= buffer.fullCount {
                    lastScrolled = newCount
                    proxy.scrollTo(ChatView.bottomAnchor, anchor: .bottom)
                }
                if finishing && newCount >= buffer.fullCount {
                    onFinishedReveal()
                }
            }
            // Covers the case where the reveal already caught up before the
            // network turn ended (count won't change, so onChange(count) won't
            // fire) — finishLiveBubble is idempotent, so a double call is safe.
            .onChange(of: finishing) { _, isFinishing in
                if isFinishing && count >= buffer.fullCount {
                    onFinishedReveal()
                }
            }
        }
    }

    /// Buffered, rate-limited reveal (frame-rate independent via the timestamp
    /// delta). The rate scales with the backlog but is HARD-CAPPED — Claude
    /// streams in fast bursts, so without a cap the reveal would dump hundreds
    /// of characters at once ("finishes very fast"). The cap also means the
    /// backlog stays ahead of the reveal during streaming, so it types
    /// continuously at a steady pace and the gaps between network bursts are
    /// hidden by that cushion (no mid-stream freeze).
    private func advance(to date: Date, target: Double) {
        let dt = clock.last.map { min(date.timeIntervalSince($0), 0.1) } ?? 0
        clock.last = date
        let remaining = target - clock.revealed
        guard remaining > 0 else { clock.revealed = target; return }
        let minCharsPerSecond = 22.0
        let maxCharsPerSecond = 70.0
        let smoothingWindow = 0.6 // aim to show the current backlog over ~0.6s
        let cps = min(maxCharsPerSecond, max(minCharsPerSecond, remaining / smoothingWindow))
        clock.revealed = min(target, clock.revealed + cps * dt)
    }
}

/// Animated "Max is thinking" bubble, rendered inline in the message list.
private struct TypingIndicator: View {
    var body: some View {
        HStack {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glassEffect(
                    .regular.tint(Color.white.opacity(0.06)),
                    in: .rect(cornerRadius: 16, style: .continuous)
                )
            Spacer(minLength: 80)
        }
        .transition(.opacity)
    }
}

private struct MessageRow: View {
    let message: ChatMessageVM
    @EnvironmentObject var state: AppState

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(state.chatFont(0, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(
                        .regular.tint(Color.accentColor.opacity(0.45)),
                        in: .rect(cornerRadius: 16, style: .continuous)
                    )
            }

        case .assistant:
            HStack {
                markdown(message.text)
                    .font(state.chatFont())
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(
                        .regular.tint(Color.white.opacity(0.06)),
                        in: .rect(cornerRadius: 16, style: .continuous)
                    )
                Spacer(minLength: 80)
            }

        case .tool(let name, let isError):
            HStack(spacing: 6) {
                Image(systemName: iconFor(tool: name))
                    .font(.system(size: 10, weight: .bold))
                Text(message.text)
                    .font(.system(size: max(9, state.config.fontSize - 2.5), weight: .semibold, design: .monospaced))
                    .lineLimit(2)
            }
            .foregroundStyle(isError ? Color.red.opacity(0.9) : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(
                .regular.tint(isError ? Color.red.opacity(0.18) : Color.white.opacity(0.04)),
                in: .capsule
            )

        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(state.chatFont(-1.5, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(Color.red.opacity(0.2)), in: .rect(cornerRadius: 12))
        }
    }

    private func markdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func iconFor(tool: String) -> String {
        switch tool {
        case "exec": return "terminal.fill"
        case "applescript": return "applescript.fill"
        case "read_file": return "doc.text.fill"
        case "write_file": return "square.and.pencil"
        case "loop": return "arrow.triangle.2.circlepath"
        case "see_screen": return "eye.fill"
        case "read_screen_text": return "text.viewfinder"
        default: return "wrench.and.screwdriver.fill"
        }
    }
}
