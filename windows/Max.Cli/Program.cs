using Max.Core;

// Tiny console harness for Max.Core — lets us exercise the agent brain on any OS
// (no WinUI needed). Set ANTHROPIC_API_KEY (or OPENAI_API_KEY) and run:
//   dotnet run --project Max.Cli -- "what time is it?"

MaxPaths.Root = Environment.GetEnvironmentVariable("MAX_HOME")
    ?? Path.Combine(Path.GetTempPath(), "max-cli");
MaxPaths.Ensure();

var config = MaxConfig.Load();
config.UserName = Environment.UserName;
config.ExecApproval = Environment.GetEnvironmentVariable("MAX_ASK") == "1"
    ? ExecApprovalMode.Ask : ExecApprovalMode.Auto;

var providerEnv = Environment.GetEnvironmentVariable("MAX_PROVIDER");
if (providerEnv is not null && Enum.TryParse<LLMProviderKind>(providerEnv, true, out var pk)) config.Provider = pk;
if (Environment.GetEnvironmentVariable("MAX_MODEL") is { Length: > 0 } m) config.Model = m;

ISecretStore secrets = new FileSecretStore();
if (Environment.GetEnvironmentVariable("ANTHROPIC_API_KEY") is { Length: > 0 } ak) secrets.Set("anthropic", ak);
if (Environment.GetEnvironmentVariable("OPENAI_API_KEY") is { Length: > 0 } ok) secrets.Set("openai", ok);

if (config.ProviderNeedsApiKey && string.IsNullOrEmpty(secrets.ApiKey(config.Provider)))
{
    Console.Error.WriteLine($"No API key for {config.Provider}. Set ANTHROPIC_API_KEY or OPENAI_API_KEY.");
    return 1;
}

var session = new ChatSession(Conversations.NewId());
var tools = AgentLoop.BaseTools(config);

Func<string, Task<bool>> approval = summary =>
{
    Console.Write($"\n[approve] {summary}  (y/N) ");
    var line = Console.ReadLine();
    return Task.FromResult(line?.Trim().Equals("y", StringComparison.OrdinalIgnoreCase) == true);
};

async Task RunTurn(string text)
{
    Console.WriteLine($"\n> {text}");
    await foreach (var ev in AgentLoop.RunAsync(session, text, config, secrets, tools, approval))
    {
        switch (ev)
        {
            case AgentEvent.TextDelta td: Console.Write(td.Text); break;
            case AgentEvent.ToolStarted ts: Console.WriteLine($"\n[tool] {ts.Name}: {ts.Summary}"); break;
            case AgentEvent.ToolFinished tf when tf.IsError: Console.WriteLine($"  [error] {tf.ResultPreview}"); break;
            case AgentEvent.Failed f: Console.WriteLine($"\n[failed] {f.Message}"); break;
            case AgentEvent.TurnEnded: Console.WriteLine(); break;
        }
    }
}

if (args.Length > 0)
{
    await RunTurn(string.Join(' ', args));
    return 0;
}

Console.WriteLine($"Max ({config.Provider}/{config.Model}) — type a message, Ctrl-D to quit.");
string? input;
while ((input = Console.ReadLine()) is not null)
{
    if (input.Trim().Length == 0) continue;
    await RunTurn(input);
}
return 0;
