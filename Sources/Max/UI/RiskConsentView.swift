import SwiftUI

/// First-run disclaimer. Max has full access to this Mac; the user must
/// acknowledge what that means before using it.
struct RiskConsentView: View {
    let onAccept: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — pinned (always visible)
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                Text("Before you use Max")
                    .font(.system(size: 20, weight: .bold))
            }
            .padding(.bottom, 14)

            // Disclaimer — scrolls if the window is short, so nothing gets cut off
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Max is an AI assistant with full, hands-on control of this Mac. By continuing you understand:")
                        .font(.system(size: 13))

                    VStack(alignment: .leading, spacing: 9) {
                        bullet("It can run shell commands, control apps, read and write files, see your screen, and act on any other Macs you connect.")
                        bullet("It acts on instructions from the AI model — and AI can be wrong or be manipulated by content it reads (web pages, messages, files). A bad instruction could delete data or expose information.")
                        bullet("What Max sees — screen, files, command output — is sent to the AI provider whose key you supply.")
                        bullet("If you enable chat channels (iMessage, Telegram, Discord, Slack), anyone on your allowlist can drive Max remotely.")
                    }

                    Text("Protect yourself: keep \"Require approval\" on, use the command denylist, set a spend limit, and only allowlist people you trust. This software is provided as-is, with no warranty — you use it at your own risk.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing, 6) // breathing room for the scroll indicator
            }
            .frame(maxHeight: .infinity)

            // Actions — pinned (always reachable, never clipped)
            HStack {
                Button("Quit") { onQuit() }
                Spacer()
                Button("I understand — enable full access") { onAccept() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 12)
        }
        .padding(24)
        .frame(width: 540)
        .frame(minHeight: 300)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.system(size: 13, weight: .bold))
            Text(text).font(.system(size: 13))
        }
    }
}
