<p align="center">
  <a href="https://www.youtube.com/watch?v=fAvWczONMqc">
    <img src="https://img.youtube.com/vi/fAvWczONMqc/hqdefault.jpg" alt="Watch the Max demo" width="640">
  </a>
</p>
<p align="center"><a href="https://www.youtube.com/watch?v=fAvWczONMqc"><b>▶ Watch the demo</b></a></p>

# Max

Max is a native Mac assistant that operates your computer. Summon it with a keystroke, tell it what you want in plain language, and it runs apps, manages files, executes commands, and reads your screen to get the job done.

**[⬇ Download for Mac](https://github.com/FlayrLabs/max/releases/latest/download/Max-macos.zip)**  ·  [trymax.io](https://trymax.io)

> Max has real control of your Mac and carries out AI-generated actions. Keep approvals on, set a spend limit, and only allowlist people you trust. Provided as-is, without warranty — use at your own risk.

## Requirements

- macOS 26 (Tahoe) or later
- An AI provider key (Anthropic or OpenAI) — or run locally and free with [Ollama](https://ollama.com)

## Install

1. Download **Max-macos.zip** and unzip it.
2. Drag **Max.app** into your Applications folder.
3. Open it. Max has no Dock window — it lives in the menu bar (the duck icon). Press **⌥Space** to summon it.

The download is signed and notarized by Apple, so it opens normally — no security workarounds needed.

## First run

1. Accept the one-time risk notice.
2. Open **Settings** (menu-bar duck → Settings) → **Model**, and either paste an API key (stored in the macOS Keychain) or select **Ollama** for local models.
3. Grant the permissions Max requests as you use it: **Screen Recording** and **Accessibility** (to see and read the screen), **Automation** (to control apps), and **Full Disk Access** (only if you enable the iMessage channel).

## What it can do

Type a request and Max carries it out — for example:

- "Clean up my Downloads folder and sort everything by type."
- "Read the error on my screen and fix it."
- "Install Tor Browser and open it."
- "Rename these screenshots by date."

It can also:

- **Run on a schedule** — create *Loops* that run on their own, e.g. "every morning at 8, summarize my calendar and text it to me."
- **Work from your phone** — connect Telegram, Discord, Slack, or iMessage and control your Mac from anywhere.
- **Reach your other Macs** — run commands on machines you've added, over SSH.

## Your keys, your data

- Bring your own Anthropic or OpenAI key, or run fully local with Ollama. Nothing leaves your Mac except the model requests you choose to make.
- API keys and channel tokens are stored in the macOS Keychain, never in plaintext.
- Config, conversations, and logs live in `~/.max/`. Every action Max takes is recorded in `~/.max/actions.log`.

## Safety

- **Approvals** — by default Max asks before running each command you start from the desktop. (Scheduled loops and channel messages run unattended, so they rely on the denylist.)
- **Command denylist** — dangerous commands are hard-blocked everywhere, on by default; add your own patterns.
- **Spend limit** — a daily USD cap; Max stops when it's reached. Local models are free.
- **Allowlists** — channels only respond to the user IDs you add.
- **Kill switch** — pause all activity instantly from the menu bar.

These reduce risk but don't eliminate it. AI can be wrong, or misled by content it reads. Review what Max does.

## Build from source

Requires the Xcode 26 command-line tools (Swift 6, macOS 26 SDK).

```sh
./scripts/build-app.sh   # → dist/Max.app
open dist/Max.app
```

## License

MIT — see [LICENSE](LICENSE). © 2026 Flayr Labs LLC.
