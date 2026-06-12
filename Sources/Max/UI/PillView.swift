import SwiftUI

/// The flowing conic-gradient outline from flayr-studio's "closed_working" pill state —
/// blue → purple → pink, 4s spin.
struct WorkingOutline: View {
    var cornerRadius: CGFloat = 30

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = Angle(degrees: (t.truncatingRemainder(dividingBy: 4)) / 4 * 360)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.38, green: 0.65, blue: 0.98).opacity(0.9),
                            Color(red: 0.75, green: 0.52, blue: 0.99),
                            Color(red: 0.96, green: 0.45, blue: 0.71).opacity(0.9),
                            Color(red: 0.75, green: 0.52, blue: 0.99),
                            Color(red: 0.38, green: 0.65, blue: 0.98).opacity(0.9),
                        ]),
                        center: .center,
                        angle: angle
                    ),
                    lineWidth: 2.5
                )
                .blur(radius: 0.5)
                .shadow(color: Color(red: 0.6, green: 0.5, blue: 0.99).opacity(0.45), radius: 8)
        }
        .allowsHitTesting(false)
    }
}

/// The Max pill — bottom-center Liquid Glass input, modeled on the flayr-studio
/// chat pill (Enter submits + opens the chat, chevron toggles, outline = working).
struct PillView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var focusBus = FocusBus.shared
    @FocusState private var focused: Bool

    private var busy: Bool { state.isWorking || state.loopActivity }

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                DuckIcon(size: 24)
                    .opacity(busy ? 0.6 : 1)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: busy)

                TextField("Ask Max to do anything…", text: $state.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(state.chatFont(1.5, weight: .semibold))
                    .lineLimit(1...3)
                    .focused($focused)
                    .onSubmit { state.submitDraft() }

                if state.isWorking {
                    Button(action: { state.stop() }) {
                        Label("Stop", systemImage: "square.fill")
                            .font(.system(size: 11, weight: .bold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                } else {
                    Button(action: { state.submitDraft() }) {
                        Label("Enter", systemImage: "return")
                            .font(.system(size: 11, weight: .bold))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Button(action: { state.toggleChat() }) {
                    Image(systemName: state.chatOpen ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .padding(6)
                }
                .buttonStyle(.glass)
                .help(state.chatOpen ? "Hide chat" : "Show chat")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .glassEffect(
                .regular.interactive(),
                in: .rect(cornerRadius: 30, style: .continuous)
            )
            .overlay {
                if busy {
                    WorkingOutline(cornerRadius: 30)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .onChange(of: focusBus.pillFocusTick) {
            focused = true
        }
        .onAppear { focused = true }
    }
}
