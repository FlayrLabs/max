using System.Text.Json;
using System.Text.Json.Serialization;

namespace Max.Core;

public enum LLMProviderKind { Anthropic, OpenAI, Ollama }

public enum ExecApprovalMode { Auto, Ask }

/// <summary>On-disk locations. %LOCALAPPDATA%\Max on Windows (~/.local/share/Max on macOS for CLI testing).</summary>
public static class MaxPaths
{
    public static string Root { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Max");

    public static string Sessions => Path.Combine(Root, "sessions");
    public static string SoulFile => Path.Combine(Root, "soul.md");
    public static string ConfigFile => Path.Combine(Root, "config.json");
    public static string SpendFile => Path.Combine(Root, "spend.json");
    public static string ActionsLog => Path.Combine(Root, "actions.log");

    public static void Ensure()
    {
        Directory.CreateDirectory(Root);
        Directory.CreateDirectory(Sessions);
    }
}

/// <summary>
/// User configuration, persisted to config.json. Mirrors the macOS MaxConfig minus
/// the Apple-only bits (iMessage); channels + safety + hotkey carry over verbatim.
/// </summary>
public sealed class MaxConfig
{
    public string UserName { get; set; } = "";
    public LLMProviderKind Provider { get; set; } = LLMProviderKind.Anthropic;
    public string Model { get; set; } = "claude-opus-4-8";

    public ExecApprovalMode ExecApproval { get; set; } = ExecApprovalMode.Ask;
    public bool Onboarded { get; set; }
    public bool AcknowledgedRisk { get; set; }
    public bool Paused { get; set; }

    public List<string> CommandDenylist { get; set; } = new();
    public bool UseDefaultDenylist { get; set; } = true;
    public double DailySpendLimitUSD { get; set; } = 10.0;

    public bool AllowScreenVision { get; set; } = true;
    public bool LoopsCanSeeScreen { get; set; }

    public string OllamaBaseURL { get; set; } = "http://127.0.0.1:11434";

    // Channels (Max's own identity for two-sided chat)
    public bool TelegramEnabled { get; set; }
    public List<string> TelegramAllowlist { get; set; } = new();
    public bool DiscordEnabled { get; set; }
    public List<string> DiscordAllowlist { get; set; } = new();
    public bool SlackEnabled { get; set; }
    public List<string> SlackAllowlist { get; set; } = new();

    public bool KeepAwake { get; set; }

    // Global summon hotkey (Win32 modifiers + virtual-key); default Alt+Space.
    public uint HotKeyModifiers { get; set; } = 0x0001; // MOD_ALT
    public uint HotKeyVk { get; set; } = 0x20;          // VK_SPACE
    public string HotKeyLabel { get; set; } = "Alt+Space";

    public bool ProviderNeedsApiKey => Provider != LLMProviderKind.Ollama;

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        Converters = { new JsonStringEnumConverter() },
    };

    public static MaxConfig Load()
    {
        try
        {
            if (File.Exists(MaxPaths.ConfigFile))
                return JsonSerializer.Deserialize<MaxConfig>(File.ReadAllText(MaxPaths.ConfigFile), JsonOpts) ?? new MaxConfig();
        }
        catch { /* tolerate a partial/old config, fall back to defaults */ }
        return new MaxConfig();
    }

    public void Save()
    {
        MaxPaths.Ensure();
        File.WriteAllText(MaxPaths.ConfigFile, JsonSerializer.Serialize(this, JsonOpts));
    }
}

/// <summary>
/// Where API keys + channel tokens live. The Windows head implements this with the
/// Windows Credential Manager (DPAPI-backed); Core ships a simple file fallback so
/// the CLI/tests can run. Never log secrets.
/// </summary>
public interface ISecretStore
{
    string? Get(string key);
    void Set(string key, string value);
    void Delete(string key);

    string? ApiKey(LLMProviderKind provider) => provider switch
    {
        LLMProviderKind.Anthropic => Get("anthropic"),
        LLMProviderKind.OpenAI => Get("openai"),
        _ => null,
    };
}

/// <summary>Plain-file secret store for CLI/test use only (head replaces it on Windows).</summary>
public sealed class FileSecretStore : ISecretStore
{
    private readonly string _path = Path.Combine(MaxPaths.Root, "credentials.json");

    private Dictionary<string, string> Read()
    {
        try
        {
            if (File.Exists(_path))
                return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(_path)) ?? new();
        }
        catch { }
        return new();
    }

    private void Write(Dictionary<string, string> d)
    {
        MaxPaths.Ensure();
        File.WriteAllText(_path, JsonSerializer.Serialize(d));
    }

    public string? Get(string key) => Read().TryGetValue(key, out var v) ? v : null;
    public void Set(string key, string value) { var d = Read(); d[key] = value; Write(d); }
    public void Delete(string key) { var d = Read(); if (d.Remove(key)) Write(d); }
}
