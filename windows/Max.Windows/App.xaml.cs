using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Max.Core;
using Max.Windows.Platform;

namespace Max.Windows;

/// <summary>
/// App bootstrap. Accessory-style: no main window on the taskbar — a global hotkey
/// (default Alt+Space) summons the pill, mirroring the macOS menu-bar app.
/// </summary>
public partial class App : Application
{
    private PillWindow? _pill;
    private GlobalHotKey? _hotKey;
    private DispatcherQueue? _ui;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _ui = DispatcherQueue.GetForCurrentThread();
        _pill = new PillWindow();
        _pill.Activate();

        var config = MaxConfig.Load();
        _hotKey = new GlobalHotKey(config.HotKeyModifiers, config.HotKeyVk);
        _hotKey.Pressed += () => _ui?.TryEnqueue(() => _pill?.Toggle());
        _hotKey.Start();
    }
}
