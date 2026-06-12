using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;

namespace Max.Core;

/// <summary>
/// The agentic loop, ported from the macOS AgentLoop:
/// user message → stream LLM → run tool calls → feed results back → repeat until
/// a turn produces no tool calls. Emits <see cref="AgentEvent"/>s for the UI and
/// appends to the session transcript as it goes.
/// </summary>
public static class AgentLoop
{
    private const int MaxIterations = 30;
    private static readonly HashSet<string> NeedsApproval = new(StringComparer.OrdinalIgnoreCase)
    { "exec", "powershell", "remote_exec", "control_app" };

    public static ILLMProvider CreateProvider(MaxConfig config) => config.Provider switch
    {
        LLMProviderKind.Anthropic => new AnthropicProvider(),
        LLMProviderKind.OpenAI => new OpenAIProvider(),
        LLMProviderKind.Ollama => new OpenAIProvider(NormalizeOllama(config.OllamaBaseURL), requiresKey: false),
        _ => new AnthropicProvider(),
    };

    public static List<IMaxTool> BaseTools(MaxConfig config) =>
        new() { new ExecTool(config), new ReadFileTool(), new WriteFileTool(), new LoopTool() };

    /// <param name="tools">The full tool set (base tools + any platform tools from the head).</param>
    /// <param name="approval">Ask-mode gate. Returns true to allow. Null = auto-approve.</param>
    public static async IAsyncEnumerable<AgentEvent> RunAsync(
        ChatSession session, string userText, MaxConfig config, ISecretStore secrets,
        IReadOnlyList<IMaxTool> tools,
        Func<string, Task<bool>>? approval = null,
        bool isLoopRun = false, bool isRemoteOrigin = false,
        IReadOnlyList<ImagePayload>? images = null,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        if (config.Paused)
        {
            yield return new AgentEvent.Failed("Max is paused. Resume from the tray icon to use it.");
            yield break;
        }
        if (SpendTracker.IsOverLimit(config))
        {
            yield return new AgentEvent.Failed($"Daily spend limit (${config.DailySpendLimitUSD:0.00}) reached. Raise it in Settings.");
            yield break;
        }

        var includeVision = isLoopRun ? (config.AllowScreenVision && config.LoopsCanSeeScreen) : config.AllowScreenVision;
        var registry = new ToolRegistry(tools);
        var provider = CreateProvider(config);
        var apiKey = secrets.ApiKey(config.Provider) ?? "";
        var system = SystemPrompt.Build(config, isLoopRun, includeVision);

        var firstBlocks = new List<ContentBlock> { new ContentBlock.Text(userText) };
        if (images != null) firstBlocks.AddRange(images.Select(i => new ContentBlock.Image(i)));
        session.Append(new ChatTurn(Role.User, firstBlocks));

        var finalText = "";

        for (var iter = 0; iter < MaxIterations; iter++)
        {
            ct.ThrowIfCancellationRequested();

            IReadOnlyList<ContentBlock>? completedBlocks = null;
            var stopReason = "end_turn";

            await using var e = provider
                .StreamTurnAsync(system, PruneImages(session.Turns), registry.Specs, config.Model, apiKey, ct)
                .GetAsyncEnumerator(ct);

            while (true)
            {
                ProviderEvent? ev = null;
                var moved = false;
                var canceled = false;
                string? streamError = null;
                try
                {
                    moved = await e.MoveNextAsync();
                    if (moved) ev = e.Current;
                }
                catch (OperationCanceledException) { canceled = true; }
                catch (Exception ex) { streamError = ex.Message; }

                if (canceled) yield break;
                if (streamError != null) { yield return new AgentEvent.Failed(streamError); yield break; }
                if (!moved || ev is null) break;

                switch (ev)
                {
                    case ProviderEvent.TextDelta td:
                        yield return new AgentEvent.TextDelta(td.Text);
                        break;
                    case ProviderEvent.TurnCompleted tc:
                        completedBlocks = tc.Blocks;
                        stopReason = tc.StopReason;
                        break;
                    case ProviderEvent.Usage u:
                        SpendTracker.Record(config.Model, u.InputTokens, u.OutputTokens);
                        break;
                }
            }

            if (completedBlocks is null)
            {
                yield return new AgentEvent.Failed("model stream ended unexpectedly");
                yield break;
            }

            session.Append(new ChatTurn(Role.Assistant, completedBlocks));
            foreach (var b in completedBlocks)
                if (b is ContentBlock.Text t) finalText = t.Value;

            var toolUses = completedBlocks.OfType<ContentBlock.ToolUse>().ToList();
            if (stopReason != "tool_use" || toolUses.Count == 0) break;

            var results = new List<ContentBlock>();
            foreach (var use in toolUses)
            {
                ct.ThrowIfCancellationRequested();
                var input = ParseObject(use.InputJson);
                var tool = registry.Get(use.Name);
                if (tool is null)
                {
                    results.Add(new ContentBlock.ToolResult(use.Id, $"unknown tool {use.Name}", true, Array.Empty<ImagePayload>()));
                    continue;
                }

                var summary = tool.Summary(input);
                yield return new AgentEvent.ToolStarted(use.Name, summary);

                if (config.ExecApproval == ExecApprovalMode.Ask && !isLoopRun && !isRemoteOrigin
                    && NeedsApproval.Contains(use.Name) && approval != null)
                {
                    var ok = await approval(summary);
                    if (!ok)
                    {
                        ActionLog.Write($"DENIED {use.Name}: {summary}");
                        results.Add(new ContentBlock.ToolResult(use.Id, "User denied this command.", true, Array.Empty<ImagePayload>()));
                        yield return new AgentEvent.ToolFinished(use.Name, "denied", true);
                        continue;
                    }
                }

                ToolOutcome outcome;
                try { outcome = await tool.ExecuteAsync(input, ct); }
                catch (Exception ex) { outcome = ToolOutcome.Fail(ex.Message); }

                ActionLog.Write($"{(outcome.IsError ? "ERROR" : "ran")} {use.Name}: {summary}");
                results.Add(new ContentBlock.ToolResult(use.Id, outcome.Content, outcome.IsError, outcome.Images));
                yield return new AgentEvent.ToolFinished(use.Name,
                    outcome.Content.Length > 200 ? outcome.Content[..200] : outcome.Content, outcome.IsError);
            }

            session.Append(new ChatTurn(Role.User, results));
        }

        yield return new AgentEvent.TurnEnded(finalText);
    }

    /// <summary>Keep only the newest <paramref name="keep"/> image-bearing tool results on the wire.</summary>
    private static IReadOnlyList<ChatTurn> PruneImages(IReadOnlyList<ChatTurn> turns, int keep = 2)
    {
        var imageTurnIndices = new List<int>();
        for (var i = 0; i < turns.Count; i++)
            if (turns[i].Blocks.Any(b => b is ContentBlock.ToolResult r && r.Images.Count > 0))
                imageTurnIndices.Add(i);

        var drop = imageTurnIndices.Take(Math.Max(0, imageTurnIndices.Count - keep)).ToHashSet();
        if (drop.Count == 0) return turns;

        var outList = new List<ChatTurn>(turns.Count);
        for (var i = 0; i < turns.Count; i++)
        {
            if (!drop.Contains(i)) { outList.Add(turns[i]); continue; }
            var blocks = turns[i].Blocks.Select(b => b is ContentBlock.ToolResult r && r.Images.Count > 0
                ? new ContentBlock.ToolResult(r.ToolUseId, r.Content + "\n[screenshot omitted from context — take a fresh one if needed]", r.IsError, Array.Empty<ImagePayload>())
                : b);
            outList.Add(new ChatTurn(turns[i].Role, blocks));
        }
        return outList;
    }

    private static JsonObject ParseObject(string json)
    {
        try { return JsonNode.Parse(string.IsNullOrWhiteSpace(json) ? "{}" : json)?.AsObject() ?? new JsonObject(); }
        catch { return new JsonObject(); }
    }

    private static string NormalizeOllama(string baseUrl)
    {
        var b = baseUrl.Trim().TrimEnd('/');
        return $"{b}/v1/chat/completions";
    }
}
