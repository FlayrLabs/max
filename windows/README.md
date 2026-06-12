# Max for Windows

A native Windows port of Max (the macOS Liquid Glass assistant). Same agent brain,
same BYO-LLM model, Windows-native shell.

## Why this layout

Max's macOS app is Swift/AppKit/Liquid Glass — none of that runs on Windows. But the
*agent* is platform-agnostic. So this port splits cleanly:

| Project | TFM | Builds on | What it is |
|---|---|---|---|
| **`Max.Core`** | `net8.0` | any OS | The brain — agent loop, Anthropic/OpenAI/Ollama providers (raw SSE), tools, safety (denylist/spend/audit), sessions, config. No UI, no OS-specific APIs. |
| **`Max.Cli`** | `net8.0` | any OS | A console harness to exercise `Max.Core` without a GUI. |
| **`Max.Windows`** | `net8.0-windows10.0.19041.0` | **Windows only** | The WinUI 3 head — pill + chat window (Mica), global hotkey, Windows Credential Manager, screen capture. |

`Max.Core` + `Max.Cli` are in **`Max.sln`** (cross-platform). `Max.Core` + `Max.Windows`
are in **`Max.Windows.sln`** (open this one in Visual Studio on Windows).

## Status

- ✅ **`Max.Core` is implemented and verified** — built on macOS and smoke-tested end to
  end against the real Anthropic API: the model streamed, called the `exec` tool, the
  result fed back, and it answered. The full agentic loop works.
- ✅ **Windows platform pieces written:** `CredentialSecretStore` (Credential Manager),
  `GlobalHotKey` (`RegisterHotKey`), `ScreenCaptureTool` (`see_screen` via GDI).
- 🚧 **WinUI head (`App` + `PillWindow`) is a first pass** — written but only *buildable on
  Windows* (Windows App SDK). Expect to iterate on the UI there.

## macOS ⇄ Windows mapping

| macOS (Swift) | Windows (this port) |
|---|---|
| Keychain | Windows Credential Manager (`CredentialSecretStore`) |
| Carbon `RegisterEventHotKey` | `RegisterHotKey` (`GlobalHotKey`) |
| `screencapture` | GDI `CopyFromScreen` → JPEG (`ScreenCaptureTool`) |
| AppleScript | PowerShell / UI Automation (TODO: `control_app` tool) |
| `read_screen_text` (AXUIElement) | UI Automation tree (TODO) |
| `caffeinate` | `SetThreadExecutionState` (TODO) |
| Liquid Glass | Mica backdrop (`SystemBackdrop = MicaBackdrop`) |
| iMessage channel | n/a — Telegram/Discord/Slack channels port directly (TODO) |

## Build & run

### The brain (works on this Mac, or anywhere)
```bash
# from windows/
export ANTHROPIC_API_KEY=sk-ant-...
dotnet run --project Max.Cli -- "open notepad and type hello"
# options: MAX_MODEL=claude-haiku-4-5  MAX_PROVIDER=openai  MAX_ASK=1 (approve each command)
```

### The Windows app (on a Windows 10/11 machine)
Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download) + the Windows App SDK
workload (Visual Studio 2022 → "Windows App SDK / WinUI" component).
```powershell
cd windows
dotnet build Max.Windows.sln -c Release -r win-x64
# or open Max.Windows.sln in Visual Studio 2022 and F5
```
First run: it lives behind a global hotkey (default **Alt+Space**) — press it to summon
the pill. Set your API key via the Credential Manager target `Max/anthropic` (Settings UI TODO).

## Data locations
- Config: `%LOCALAPPDATA%\Max\config.json`
- Sessions (JSONL): `%LOCALAPPDATA%\Max\sessions\`
- Spend / audit: `%LOCALAPPDATA%\Max\spend.json`, `actions.log`
- Secrets: Windows Credential Manager, targets `Max/<key>`

## Next steps (head)
1. Settings UI (provider/model/key, denylist, spend cap, hotkey, channels).
2. `control_app` tool (PowerShell + UI Automation) and `read_screen_text` (UIA tree).
3. System-tray icon + pause kill-switch.
4. Channels (Telegram/Discord/Slack) — the macOS implementations port almost verbatim.
5. Package as a signed, downloadable `.exe` (self-contained); wire into the website's Download.
