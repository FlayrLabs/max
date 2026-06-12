using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;
using Windows.UI;
using Max.Core;
using Max.Windows.Platform;

namespace Max.Windows;

/// <summary>
/// The Spotlight-style pill + chat overlay — the Windows analog of the macOS
/// FloatingPanel. Mica backdrop, summoned by the global hotkey, streams a turn
/// from <see cref="AgentLoop"/> through Max.Core.
/// </summary>
public sealed partial class PillWindow : Window
{
    private readonly MaxConfig _config = MaxConfig.Load();
    private readonly ISecretStore _secrets = new CredentialSecretStore();
    private readonly ChatSession _session;
    private readonly IReadOnlyList<IMaxTool> _tools;
    private CancellationTokenSource? _turnCts;
    private bool _busy;

    public PillWindow()
    {
        InitializeComponent();

        Title = "Max";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;

        AppWindow.Resize(new SizeInt32(760, 520));
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            p.IsResizable = true;
            p.SetBorderAndTitleBar(true, false);
        }
        CenterOnScreen();

        _session = new ChatSession(Conversations.MostRecentId() ?? Conversations.NewId());
        _tools = WindowsToolset.ForInteractive(_config);

        AddBubble("Max", "Hey — I'm Max. Ask me to do anything on this PC.", isUser: false);
        Root.Loaded += async (_, _) => await ShowConsentIfNeededAsync();
    }

    private async Task ShowConsentIfNeededAsync()
    {
        if (_config.AcknowledgedRisk) return;
        var dialog = new ContentDialog
        {
            Title = "Use at your own risk",
            Content = "Max can run commands, control apps, and read your screen on this PC using your own AI key. " +
                      "It's powerful — review what it does, keep the command denylist on, and set a spend limit. " +
                      "You accept full responsibility for actions it takes.",
            PrimaryButtonText = "I understand",
            CloseButtonText = "Quit",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Root.XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            _config.AcknowledgedRisk = true;
            _config.Save();
        }
        else { Application.Current.Exit(); }
    }

    public void Toggle()
    {
        if (AppWindow.IsVisible) AppWindow.Hide();
        else { AppWindow.Show(); Activate(); Input.Focus(FocusState.Programmatic); }
    }

    private void CenterOnScreen()
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new PointInt32(
            area.X + (area.Width - AppWindow.Size.Width) / 2,
            area.Y + (area.Height - AppWindow.Size.Height) / 3));
    }

    private void Input_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter) { e.Handled = true; _ = SubmitAsync(); }
        else if (e.Key == VirtualKey.Escape) AppWindow.Hide();
    }

    private void Send_Click(object sender, RoutedEventArgs e) => _ = SubmitAsync();

    private async Task SubmitAsync()
    {
        var text = Input.Text.Trim();
        if (text.Length == 0 || _busy) return;

        Input.Text = "";
        AddBubble("You", text, isUser: true);
        _busy = true;
        SendBtn.IsEnabled = false;
        _turnCts = new CancellationTokenSource();

        var live = AddBubble("Max", "", isUser: false);

        try
        {
            await foreach (var ev in AgentLoop.RunAsync(
                _session, text, _config, _secrets, _tools, ApproveAsync, ct: _turnCts.Token))
            {
                switch (ev)
                {
                    case AgentEvent.TextDelta td:
                        live.Text += td.Text;
                        ScrollToBottom();
                        break;
                    case AgentEvent.ToolStarted ts:
                        AddBubble("·", $"⚙ {ts.Summary}", isUser: false, dim: true);
                        live = AddBubble("Max", "", isUser: false);
                        break;
                    case AgentEvent.Failed f:
                        live.Text = "⚠ " + f.Message;
                        break;
                }
            }
        }
        catch (Exception ex) { live.Text = "⚠ " + ex.Message; }
        finally
        {
            _busy = false;
            SendBtn.IsEnabled = true;
            Input.Focus(FocusState.Programmatic);
        }
    }

    private async Task<bool> ApproveAsync(string summary)
    {
        var dialog = new ContentDialog
        {
            Title = "Max wants to run a command",
            Content = summary,
            PrimaryButtonText = "Allow",
            CloseButtonText = "Deny",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Root.XamlRoot,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private TextBlock AddBubble(string who, string text, bool isUser, bool dim = false)
    {
        var body = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Foreground = new SolidColorBrush(dim ? Color.FromArgb(160, 200, 200, 210) : Colors.White),
            FontSize = dim ? 12 : 14,
        };
        var border = new Border
        {
            Background = new SolidColorBrush(isUser
                ? Color.FromArgb(40, 120, 130, 255)
                : Color.FromArgb(28, 255, 255, 255)),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(12, 8, 12, 8),
            HorizontalAlignment = isUser ? HorizontalAlignment.Right : HorizontalAlignment.Left,
            MaxWidth = 620,
            Child = body,
        };
        ChatStack.Children.Add(border);
        ScrollToBottom();
        return body;
    }

    private void ScrollToBottom()
    {
        ChatScroll.UpdateLayout();
        ChatScroll.ChangeView(null, ChatScroll.ScrollableHeight, null, disableAnimation: true);
    }
}
