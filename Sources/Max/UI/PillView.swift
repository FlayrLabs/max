import SwiftUI
import UniformTypeIdentifiers

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
    @State private var dropTarget = false

    private var busy: Bool { state.isWorking || state.loopActivity }
    private var canSubmit: Bool {
        !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !state.pendingAttachments.isEmpty
    }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 8) {
                if !state.pendingAttachments.isEmpty {
                    attachmentStrip
                }
                inputRow
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
                } else if dropTarget {
                    dropOverlay
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTarget) { providers in
                state.handleDrop(providers)
                return true
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .onChange(of: focusBus.pillFocusTick) {
            focused = true
        }
        .onAppear { focused = true }
    }

    /// Busy pulse driven by a TimelineView (not a `.repeatForever` animation modifier),
    /// so a layout change — like an attachment appearing — can't make the duck oscillate
    /// or "jump" out of the pill.
    @ViewBuilder private var duck: some View {
        if busy {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                DuckIcon(size: 24).opacity(0.55 + 0.45 * abs(sin(t * 2.4)))
            }
        } else {
            DuckIcon(size: 24)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            duck

            TextField("Ask Max to do anything…", text: $state.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(state.chatFont(1.5, weight: .semibold))
                .lineLimit(1...3)
                .focused($focused)
                .onSubmit { state.submitDraft() }

            Button(action: { state.pickAttachment() }) {
                Image(systemName: "paperclip")
                    .font(.system(size: 12, weight: .bold))
                    .padding(6)
            }
            .buttonStyle(.glass)
            .help("Attach a file or image — or drop one onto the pill")

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
                .disabled(!canSubmit)
            }

            Button(action: { state.toggleChat() }) {
                Image(systemName: state.chatOpen ? "chevron.down" : "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .padding(6)
            }
            .buttonStyle(.glass)
            .help(state.chatOpen ? "Hide chat" : "Show chat")
        }
    }

    /// Obvious "you can drop here" affordance shown while a drag hovers the pill.
    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            HStack(spacing: 8) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                Text("Drop image or file to attach")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
        }
        .allowsHitTesting(false)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(state.pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.isImage ? "photo.fill" : "doc.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(attachment.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 140)
                        Button { state.removeAttachment(attachment.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.tint(.white.opacity(0.06)), in: .capsule)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
