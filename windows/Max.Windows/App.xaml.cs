using H.NotifyIcon;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Max.Core;
using Max.Windows.Platform;

namespace Max.Windows;

/// <summary>Shared, app-lifetime services reachable from any window.</summary>
public sealed record AppServices(ISecretStore Secrets, ChannelHost Channels, LoopScheduler Loops);

/// <summary>
/// App bootstrap. Accessory-style (no taskbar window): a global hotkey summons the pill,
/// a tray icon gives Show/Pause/Settings/Quit, and channels + the loop scheduler run in
/// the background — mirroring the macOS menu-bar app.
/// </summary>
public partial class App : Application
{
    public static AppServices Services { get; private set; } = null!;

    private PillWindow? _pill;
    private SettingsWindow? _settings;
    private GlobalHotKey? _hotKey;
    private TaskbarIcon? _tray;
    private DispatcherQueue? _ui;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _ui = DispatcherQueue.GetForCurrentThread();
        var config = MaxConfig.Load();

        var secrets = new CredentialSecretStore();
        var router = new ChannelRouter(secrets, WindowsToolset.ForInteractive);
        var channels = new ChannelHost(secrets, router);
        var loops = new LoopScheduler(secrets, WindowsToolset.ForLoop,
            (title, body) => _ui?.TryEnqueue(() => Notify(title, body)));
        Services = new AppServices(secrets, channels, loops);

        KeepAwake.Apply(config.KeepAwake);

        _pill = new PillWindow();
        _pill.Activate();

        _hotKey = new GlobalHotKey(config.HotKeyModifiers, config.HotKeyVk);
        _hotKey.Pressed += () => _ui?.TryEnqueue(() => _pill?.Toggle());
        _hotKey.Start();

        SetupTray();
        channels.StartEnabled();
        loops.Start();
    }

    public void ShowSettings()
    {
        if (_settings is null)
        {
            _settings = new SettingsWindow();
            _settings.Closed += (_, _) => _settings = null;
        }
        _settings.Activate();
    }

    private void Notify(string title, string body)
    {
        try { _tray?.ShowNotification(title: title, message: body.Length > 250 ? body[..250] : body); }
        catch { /* tray balloon best-effort */ }
    }

    private void SetupTray()
    {
        try
        {
            var menu = new MenuFlyout();

            var show = new MenuFlyoutItem { Text = "Show Max" };
            show.Click += (_, _) => _pill?.Toggle();

            var pause = new ToggleMenuFlyoutItem { Text = "Pause", IsChecked = MaxConfig.Load().Paused };
            pause.Click += (_, _) =>
            {
                var c = MaxConfig.Load();
                c.Paused = !c.Paused;
                c.Save();
                pause.IsChecked = c.Paused;
            };

            var settings = new MenuFlyoutItem { Text = "Settings…" };
            settings.Click += (_, _) => ShowSettings();

            var quit = new MenuFlyoutItem { Text = "Quit Max" };
            quit.Click += (_, _) => { _tray?.Dispose(); _hotKey?.Dispose(); Services.Channels.StopAll(); Current.Exit(); };

            menu.Items.Add(show);
            menu.Items.Add(pause);
            menu.Items.Add(settings);
            menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(quit);

            _tray = new TaskbarIcon
            {
                ToolTipText = "Max",
                ContextFlyout = menu,
                IconSource = new GeneratedIconSource { Text = "M", Foreground = Microsoft.UI.Colors.White },
            };
            _tray.LeftClickCommand = new RelayCommand(() => _pill?.Toggle());
            _tray.ForceCreate();
        }
        catch { /* tray is best-effort; the hotkey is the primary entry point */ }
    }
}

/// <summary>Minimal ICommand so the tray's left-click can toggle the pill.</summary>
public sealed class RelayCommand : System.Windows.Input.ICommand
{
    private readonly Action _action;
    public RelayCommand(Action action) => _action = action;
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => _action();
}
