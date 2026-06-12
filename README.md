# Max — "Max", your Mac's AI assistant

Max is a native macOS (Liquid Glass) personal assistant that actually operates
your Mac. Summon a floating pill with **⌥Space**, type, and Max can run shell
commands, control apps, read/write files, see your screen, schedule recurring
tasks, talk to you over iMessage/Telegram/Discord/Slack, and control your other
Macs over SSH. Bring your own LLM key (Anthropic / OpenAI) or run a local model
via Ollama.

> ⚠️ **Full access, use at your own risk.** Max executes AI-generated actions on
> your real machine. AI can be wrong or be manipulated by content it reads (web
> pages, messages, files). Keep **Require approval** on, use the **command
> denylist**, set a **spend limit**, and only allowlist people you trust. No
> warranty — you accept the risk.

## Install (downloaded build)

Because this is signed with a local/self-signed identity (not yet notarized),
macOS Gatekeeper will warn the first time:

1. Move `Max.app` to `/Applications`.
2. Right-click it → **Open** → **Open** (only needed once), **or** clear the
   quarantine flag:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Max.app
   ```
3. Launch it. There's no Dock window — look for the **sparkles bubble** in the
   menu bar, and the pill at the bottom of the screen (⌥Space toggles it).

### Permissions Max may ask for
- **Accessibility / Screen Recording** — for reading and seeing the screen.
- **Full Disk Access** — only if you enable the iMessage channel (reads the
  Messages database).
- **Automation** — the first time it controls an app via AppleScript.

## First run
1. Accept the risk disclaimer.
2. Settings (menu-bar icon → Settings) → **Model**: pick a provider and paste an
   API key (stored encrypted in the macOS Keychain), or choose **Local (Ollama)**.
3. Optional: **Safety** (approval mode, denylist, spend limit), **Channels**
   (Telegram/Discord/Slack), **Devices** (other Macs), **Loops** (schedules).

Data lives in `~/.max/` (config, soul.md, conversations, logs). Secrets are in
the Keychain, never in plaintext. Everything Max did is logged to
`~/.max/actions.log`.

## Build from source

Requires the Xcode 26+ command line tools (Swift 6, macOS 26 SDK).

```sh
./scripts/build-app.sh        # → dist/Max.app (stable self-signed)
open dist/Max.app
```

The first build creates a stable self-signed code-signing certificate
(`scripts/make-signing-cert.sh`) so macOS permissions persist across rebuilds.

## Distribute to others (notarized)

Self-signed is fine for your own machines; to hand the app to other people
without Gatekeeper warnings you need a **Developer ID Application** certificate.
The Apple account (Team **NRNU83UJ68**) already exists — you just need to create
this one cert type (one time) and an app-specific password:

1. **Create the Developer ID cert** (must be the team's Account Holder/Admin):
   Xcode → Settings → Accounts → select the team → **Manage Certificates** →
   **+** → **Developer ID Application**. (Or generate a CSR and download it from
   developer.apple.com → Certificates.) It installs into your login Keychain.
2. **App-specific password**: appleid.apple.com → Sign-In & Security →
   App-Specific Passwords → create one for "Max notarization".
3. **Build, sign, notarize, staple in one command** (Team ID is baked in):
   ```sh
   APPLE_ID="you@icloud.com" APP_PW="abcd-efgh-ijkl-mnop" ./scripts/build-app.sh
   ```
   The script auto-detects the Developer ID cert, signs with hardened runtime,
   submits to Apple, waits, and staples the ticket. Override the identity with
   `DEVELOPER_ID="Developer ID Application: … (NRNU83UJ68)"` if needed.

After that, `dist/Max.app` opens on any Mac with no warning and no quarantine
removal needed.

## Safety model (read this)
- **Approval** — "Ask" confirms each shell/AppleScript/remote command you start
  from the pill. Loops and channel messages run unattended and can't prompt.
- **Command denylist** — hard-blocks matching commands **everywhere** (pill,
  loops, channels), independent of approval mode. A dangerous-defaults set is on
  by default; add your own.
- **Spend limit** — a configurable daily USD cap estimated from token usage;
  Max stops making requests when reached. Local models are free.
- **Allowlists** — channels only respond to user IDs you add.
- **Pause** — a kill switch (menu bar or Settings → Safety) that blocks all tool
  use instantly.

These reduce risk; they don't eliminate it. Audit `~/.max/actions.log`.
