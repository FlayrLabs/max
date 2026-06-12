namespace Max.Core;

/// <summary>Owns the channel instances and starts/stops them from current config.</summary>
public sealed class ChannelHost
{
    private readonly TelegramChannel _telegram;
    private readonly DiscordChannel _discord;
    private readonly SlackChannel _slack;

    public ChannelHost(ISecretStore secrets, ChannelRouter router)
    {
        _telegram = new TelegramChannel(secrets, router);
        _discord = new DiscordChannel(secrets, router);
        _slack = new SlackChannel(secrets, router);
    }

    /// <summary>Start every channel that's enabled in config (no-op for the rest). Idempotent.</summary>
    public void StartEnabled()
    {
        _telegram.Start();
        _discord.Start();
        _slack.Start();
    }

    /// <summary>Restart a single channel after its settings change.</summary>
    public void Reload(string which)
    {
        switch (which)
        {
            case "telegram": _telegram.Stop(); _telegram.Start(); break;
            case "discord": _discord.Stop(); _discord.Start(); break;
            case "slack": _slack.Stop(); _slack.Start(); break;
        }
    }

    public void StopAll()
    {
        _telegram.Stop();
        _discord.Stop();
        _slack.Stop();
    }
}
