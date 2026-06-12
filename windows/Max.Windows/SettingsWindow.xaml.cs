using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;
using Max.Core;
using Max.Windows.Platform;

namespace Max.Windows;

/// <summary>Native settings — profile, model + key, safety, channels, loops.</summary>
public sealed partial class SettingsWindow : Window
{
    private readonly ISecretStore _secrets = new CredentialSecretStore();

    public SettingsWindow()
    {
        InitializeComponent();
        Title = "Max Settings";
        AppWindow.Resize(new SizeInt32(720, 900));
        Load();
        RefreshLoops();
    }

    private void Load()
    {
        var c = MaxConfig.Load();
        NameBox.Text = c.UserName;
        SoulBox.Text = SystemPrompt.LoadSoul() ?? "";

        ProviderBox.SelectedIndex = (int)c.Provider;
        ModelBox.Text = c.Model;
        OllamaBox.Text = c.OllamaBaseURL;
        if (_secrets.ApiKey(c.Provider) is { Length: > 0 }) KeyBox.PlaceholderText = "•••••• key saved";

        ApprovalSwitch.IsOn = c.ExecApproval == ExecApprovalMode.Ask;
        DenylistSwitch.IsOn = c.UseDefaultDenylist;
        DenylistBox.Text = string.Join(Environment.NewLine, c.CommandDenylist);
        SpendBox.Value = c.DailySpendLimitUSD;
        KeepAwakeSwitch.IsOn = c.KeepAwake;
        PauseSwitch.IsOn = c.Paused;

        TelegramSwitch.IsOn = c.TelegramEnabled;
        TelegramAllow.Text = string.Join(", ", c.TelegramAllowlist);
        if (_secrets.Get("telegram-bot") is { Length: > 0 }) TelegramToken.PlaceholderText = "•••••• token saved";
        DiscordSwitch.IsOn = c.DiscordEnabled;
        DiscordAllow.Text = string.Join(", ", c.DiscordAllowlist);
        if (_secrets.Get("discord-bot") is { Length: > 0 }) DiscordToken.PlaceholderText = "•••••• token saved";
        SlackSwitch.IsOn = c.SlackEnabled;
        SlackAllow.Text = string.Join(", ", c.SlackAllowlist);
        if (_secrets.Get("slack-bot") is { Length: > 0 }) SlackBot.PlaceholderText = "•••••• token saved";
    }

    private void SaveProfile_Click(object sender, RoutedEventArgs e)
    {
        var c = MaxConfig.Load();
        c.UserName = NameBox.Text.Trim();
        c.Onboarded = true;
        c.Save();
        try { MaxPaths.Ensure(); File.WriteAllText(MaxPaths.SoulFile, SoulBox.Text); } catch { }
    }

    private void SaveModel_Click(object sender, RoutedEventArgs e)
    {
        var c = MaxConfig.Load();
        c.Provider = (LLMProviderKind)Math.Max(0, ProviderBox.SelectedIndex);
        c.Model = ModelBox.Text.Trim();
        c.OllamaBaseURL = OllamaBox.Text.Trim();
        c.Save();
        if (KeyBox.Password.Length > 0)
        {
            var key = c.Provider == LLMProviderKind.OpenAI ? "openai" : "anthropic";
            _secrets.Set(key, KeyBox.Password);
            KeyBox.Password = "";
            KeyBox.PlaceholderText = "•••••• key saved";
        }
    }

    private void SaveSafety_Click(object sender, RoutedEventArgs e)
    {
        var c = MaxConfig.Load();
        c.ExecApproval = ApprovalSwitch.IsOn ? ExecApprovalMode.Ask : ExecApprovalMode.Auto;
        c.UseDefaultDenylist = DenylistSwitch.IsOn;
        c.CommandDenylist = DenylistBox.Text
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
        c.DailySpendLimitUSD = SpendBox.Value is double.NaN ? 0 : SpendBox.Value;
        c.KeepAwake = KeepAwakeSwitch.IsOn;
        c.Paused = PauseSwitch.IsOn;
        c.Save();
        KeepAwake.Apply(c.KeepAwake);
    }

    private void SaveChannels_Click(object sender, RoutedEventArgs e)
    {
        var c = MaxConfig.Load();
        c.TelegramEnabled = TelegramSwitch.IsOn;
        c.TelegramAllowlist = SplitIds(TelegramAllow.Text);
        c.DiscordEnabled = DiscordSwitch.IsOn;
        c.DiscordAllowlist = SplitIds(DiscordAllow.Text);
        c.SlackEnabled = SlackSwitch.IsOn;
        c.SlackAllowlist = SplitIds(SlackAllow.Text);
        c.Save();

        if (TelegramToken.Password.Length > 0) { _secrets.Set("telegram-bot", TelegramToken.Password); TelegramToken.Password = ""; }
        if (DiscordToken.Password.Length > 0) { _secrets.Set("discord-bot", DiscordToken.Password); DiscordToken.Password = ""; }
        if (SlackApp.Password.Length > 0) { _secrets.Set("slack-app", SlackApp.Password); SlackApp.Password = ""; }
        if (SlackBot.Password.Length > 0) { _secrets.Set("slack-bot", SlackBot.Password); SlackBot.Password = ""; }

        App.Services.Channels.Reload("telegram");
        App.Services.Channels.Reload("discord");
        App.Services.Channels.Reload("slack");
    }

    private void RefreshLoops_Click(object sender, RoutedEventArgs e) => RefreshLoops();

    private void RefreshLoops()
    {
        LoopsList.Items.Clear();
        foreach (var loop in LoopStore.Load())
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var label = new TextBlock
            {
                Text = $"{loop.Name} — {loop.Schedule}" +
                       (loop.Schedule == LoopSchedule.Every ? $" {loop.IntervalMinutes}m" :
                        loop.Schedule == LoopSchedule.Daily ? $" @ {loop.Time}" : $" @ {loop.AtUtc:g}"),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Grid.SetColumn(label, 0);

            var del = new Button { Content = "Delete" };
            var id = loop.Id;
            del.Click += (_, _) => { LoopStore.Delete(id); RefreshLoops(); };
            Grid.SetColumn(del, 1);

            row.Children.Add(label);
            row.Children.Add(del);
            LoopsList.Items.Add(row);
        }
    }

    private static List<string> SplitIds(string text) =>
        text.Split(new[] { ',', '\n', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Distinct().ToList();
}
