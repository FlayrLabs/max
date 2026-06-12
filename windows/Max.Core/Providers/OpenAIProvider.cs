using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json.Nodes;

namespace Max.Core;

/// <summary>
/// OpenAI Chat Completions streaming with tool calls. Reused for local Ollama via a
/// configurable endpoint and requiresKey=false (Ollama exposes an OpenAI-compatible API).
/// </summary>
public sealed class OpenAIProvider : ILLMProvider
{
    private readonly string _endpoint;
    private readonly bool _requiresKey;
    private static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };

    public OpenAIProvider(string endpoint = "https://api.openai.com/v1/chat/completions", bool requiresKey = true)
    {
        _endpoint = endpoint;
        _requiresKey = requiresKey;
    }

    public async IAsyncEnumerable<ProviderEvent> StreamTurnAsync(
        string system, IReadOnlyList<ChatTurn> turns, IReadOnlyList<ToolSpec> tools,
        string model, string apiKey, [EnumeratorCancellation] CancellationToken ct)
    {
        var messages = new JsonArray { new JsonObject { ["role"] = "system", ["content"] = system } };
        foreach (var m in WireMessages(turns)) messages.Add(m);

        var body = new JsonObject
        {
            ["model"] = model,
            ["messages"] = messages,
            ["stream"] = true,
            ["stream_options"] = new JsonObject { ["include_usage"] = true },
        };
        if (tools.Count > 0)
            body["tools"] = new JsonArray(tools.Select(t => (JsonNode)new JsonObject
            {
                ["type"] = "function",
                ["function"] = new JsonObject
                {
                    ["name"] = t.Name,
                    ["description"] = t.Description,
                    ["parameters"] = t.InputSchema.DeepClone(),
                },
            }).ToArray());

        using var req = new HttpRequestMessage(HttpMethod.Post, _endpoint);
        if (_requiresKey) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

        using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!resp.IsSuccessStatusCode)
        {
            var err = await resp.Content.ReadAsStringAsync(ct);
            throw new InvalidOperationException($"OpenAI {(int)resp.StatusCode}: {(err.Length > 500 ? err[..500] : err)}");
        }

        await using var stream = await resp.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream);

        var text = new StringBuilder();
        var toolCalls = new SortedDictionary<int, ToolCallBuilder>();
        var finishReason = "stop";

        while (!reader.EndOfStream)
        {
            ct.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(ct);
            if (line is null) break;
            if (!line.StartsWith("data: ")) continue;
            var payload = line[6..].Trim();
            if (payload.Length == 0) continue;
            if (payload == "[DONE]") break;

            JsonObject obj;
            try { obj = JsonNode.Parse(payload)!.AsObject(); } catch { continue; }

            if (obj["usage"] is JsonObject usage && usage["total_tokens"] != null)
                yield return new ProviderEvent.Usage((int?)usage["prompt_tokens"] ?? 0, (int?)usage["completion_tokens"] ?? 0);

            var choice = (obj["choices"] as JsonArray)?.FirstOrDefault()?.AsObject();
            if (choice is null) continue;

            if ((string?)choice["finish_reason"] is string fr) finishReason = fr;

            var delta = choice["delta"]?.AsObject();
            if (delta is null) continue;

            if ((string?)delta["content"] is string piece && piece.Length > 0)
            {
                text.Append(piece);
                yield return new ProviderEvent.TextDelta(piece);
            }

            if (delta["tool_calls"] is JsonArray calls)
            {
                foreach (var c in calls)
                {
                    var co = c!.AsObject();
                    var idx = (int?)co["index"] ?? 0;
                    if (!toolCalls.TryGetValue(idx, out var tb)) { tb = new ToolCallBuilder(); toolCalls[idx] = tb; }
                    if ((string?)co["id"] is string id && id.Length > 0) tb.Id = id;
                    var fn = co["function"]?.AsObject();
                    if ((string?)fn?["name"] is string nm && nm.Length > 0)
                    {
                        if (tb.Name.Length == 0) yield return new ProviderEvent.ToolUseStarted(tb.Id, nm);
                        tb.Name = nm;
                    }
                    if ((string?)fn?["arguments"] is string args) tb.Args.Append(args);
                }
            }
        }

        var blocks = new List<ContentBlock>();
        if (text.Length > 0) blocks.Add(new ContentBlock.Text(text.ToString()));
        foreach (var tb in toolCalls.Values)
            blocks.Add(new ContentBlock.ToolUse(tb.Id, tb.Name, tb.Args.Length == 0 ? "{}" : tb.Args.ToString()));

        var stopReason = finishReason == "tool_calls" ? "tool_use" : "end_turn";
        yield return new ProviderEvent.TurnCompleted(blocks, stopReason);
    }

    private static JsonArray WireMessages(IReadOnlyList<ChatTurn> turns)
    {
        var arr = new JsonArray();
        foreach (var turn in turns)
        {
            if (turn.Role == Role.User)
            {
                // Tool results become role:"tool" messages; text/images become a user message.
                var toolResults = turn.Blocks.OfType<ContentBlock.ToolResult>().ToList();
                foreach (var r in toolResults)
                    arr.Add(new JsonObject { ["role"] = "tool", ["tool_call_id"] = r.ToolUseId, ["content"] = r.Content });

                var textParts = turn.Blocks.OfType<ContentBlock.Text>().Where(t => t.Value.Length > 0).ToList();
                var imageParts = turn.Blocks.OfType<ContentBlock.Image>().ToList();
                if (textParts.Count == 0 && imageParts.Count == 0) continue;

                if (imageParts.Count == 0)
                {
                    arr.Add(new JsonObject { ["role"] = "user", ["content"] = string.Join("\n", textParts.Select(t => t.Value)) });
                }
                else
                {
                    var content = new JsonArray();
                    foreach (var t in textParts) content.Add(new JsonObject { ["type"] = "text", ["text"] = t.Value });
                    foreach (var im in imageParts)
                        content.Add(new JsonObject
                        {
                            ["type"] = "image_url",
                            ["image_url"] = new JsonObject { ["url"] = $"data:{im.Payload.MediaType};base64,{im.Payload.Base64}" },
                        });
                    arr.Add(new JsonObject { ["role"] = "user", ["content"] = content });
                }
            }
            else
            {
                var textParts = turn.Blocks.OfType<ContentBlock.Text>().Where(t => t.Value.Length > 0).ToList();
                var toolUses = turn.Blocks.OfType<ContentBlock.ToolUse>().ToList();
                var msg = new JsonObject { ["role"] = "assistant" };
                msg["content"] = textParts.Count > 0 ? string.Join("\n", textParts.Select(t => t.Value)) : null;
                if (toolUses.Count > 0)
                    msg["tool_calls"] = new JsonArray(toolUses.Select(u => (JsonNode)new JsonObject
                    {
                        ["id"] = u.Id,
                        ["type"] = "function",
                        ["function"] = new JsonObject { ["name"] = u.Name, ["arguments"] = u.InputJson },
                    }).ToArray());
                arr.Add(msg);
            }
        }
        return arr;
    }

    private sealed class ToolCallBuilder
    {
        public string Id = "";
        public string Name = "";
        public StringBuilder Args = new();
    }
}
