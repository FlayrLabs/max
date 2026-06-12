# Max for Windows

A native Windows port of Max (the macOS Liquid Glass assistant). Same agent brain,
same BYO-LLM model, Windows-native shell.

## Why this layout

Max's macOS app is Swift/AppKit/Liquid Glass — none of that runs on Windows. But the
*agent* is platform-agnostic. So this port splits cleanly:

| Project | TFM | Builds on | What it is |
|---|---|---|---|
| **`Max.Core`** | `net8.0` | any OS | The brain — agent loop, Anthropic/OpenAI/Ollama providers (raw SSE), tools, safety (denylist/spend/audit), sessions, **channels (Telegram/Discord/Slack)**, **loops (scheduler)**, config. No UI, no OS-specific APIs. |
| **`Max.Cli`** | `net8.0` | any OS | Console harness to exercise `Max.Core` without a GUI. |
| **`Max.Windows`** | `net8.0-windows10.0.19041.0` | **Windows only** | The WinUI 3 head — pill + chat (Mica), tray, settings, global hotkey, and the Windows tools. |

`Max.Core` + `Max.Cli` are in **`Max.sln`** (cross-platform). `Max.Core` + `Max.Windows`
are in **`Max.Windows.sln`** (open this in Visual Studio 2022 on Windows).

## Status

- ✅ **`Max.Core` is implemented and verified** — built on macOS and smoke-tested against
  the real Anthropic API: streaming, `exec` tool calls fed back into the loop, and the
  `loop` tool persisting a schedule all work end to end.
- ✅ **Channels (Telegram long-poll, Discord Gateway, Slack Socket Mode) + Loops scheduler**
  implemented in Core and compiling.
- ✅ **Windows platform tools written:** Credential Manager secret store, global hotkey,
  `see_screen` (GDI), `read_screen_text` (UI Automation via FlaUI), `control_app`
  (PowerShell/SendKeys), keep-awake (`SetThreadExecutionState`).
- ✅ **WinUI head written:** pill + chat (Mica), tray icon (show / pause / settings / quit),
  full Settings window, first-run risk consent, channels + loop scheduler wired into startup.
- 🚧 **Builds on Windows only** (Windows App SDK). The UI was authored on macOS and not yet
  compiled there — expect a little polish/iteration on first build.

## macOS ⇄ Windows mapping (all implemented)

| macOS (Swift) | Windows (this port) |
|---|---|
| Keychain | Windows Credential Manager (`CredentialSecretStore`) |
| Carbon `RegisterEventHotKey` | `RegisterHotKey` (`GlobalHotKey`) |
| `screencapture` | GDI `CopyFromScreen` → JPEG (`ScreenCaptureTool`) |
| `read_screen_text` (AXUIElement) | UI Automation via FlaUI (`ReadScreenTextTool`) |
| AppleScript app control | PowerShell + WScript.Shell (`AppControlTool`) |
| `caffeinate` | `SetThreadExecutionState` (`KeepAwake`) |
| Liquid Glass | Mica backdrop (`MicaBackdrop`) |
| menu-bar (accessory) app | system-tray icon (`H.NotifyIcon`) |
| Loops / channels | `LoopScheduler` / `ChannelHost` (in `Max.Core`) |
| iMessage | n/a on Windows — use Telegram/Discord/Slack |

## Build & run

### The brain (works on this Mac, or anywhere)
```bash
# from windows/
export ANTHROPIC_API_KEY=sk-ant-...
dotnet run --project Max.Cli -- "open notepad and type hello"
# options: MAX_MODEL=claude-haiku-4-5  MAX_PROVIDER=openai  MAX_ASK=1 (approve each command)
```

### The Windows app (on Windows 10/11)
Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download) and the Windows App SDK
(Visual Studio 2022 → "Windows App SDK / WinUI" workload).
```powershell
cd windows
# open Max.Windows.sln in Visual Studio 2022 and press F5, or:
dotnet build Max.Windows.sln -c Release -r win-x64
```
First run shows a risk-consent dialog. The app lives in the **system tray** + a global
hotkey (default **Alt+Space**) summons the pill. Open **Settings** (tray menu) to set your
provider/model, paste your API key, configure safety, and enable channels.

### Package a downloadable .exe
```powershell
pwsh ./publish.ps1            # produces a self-contained Max.exe (win-x64)
pwsh ./publish.ps1 -Rid win-arm64
```
Then code-sign with `signtool` (see the script output) and zip the publish folder for the
website's Download button.

## Data locations
- Config: `%LOCALAPPDATA%\Max\config.json`
- Sessions (JSONL): `%LOCALAPPDATA%\Max\sessions\`  ·  Loops: `loops.json`
- Spend / audit / channel logs: `spend.json`, `actions.log`, `channels.log`
- Secrets: Windows Credential Manager, targets `Max/<key>` (`anthropic`, `openai`, `telegram-bot`, `discord-bot`, `slack-app`, `slack-bot`)

## Known follow-ups
- Conversation switcher UI in the pill (Core already persists multiple sessions).
- Drag-and-drop of files/images onto the pill (Core's image path is ready).
- A real tray icon asset (currently a generated "M" glyph).
- Notarization-equivalent: an EV/OV code-signing cert so SmartScreen trusts the download.
