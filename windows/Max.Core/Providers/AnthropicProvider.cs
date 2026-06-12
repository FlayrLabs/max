using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json.Nodes;

namespace Max.Core;

/// <summary>
/// Anthropic Messages API via raw SSE streaming with tool use. Ports the macOS
/// AnthropicProvider: builds the wire request from ChatTurns, streams deltas, and
/// assembles the completed blocks + stop reason + token usage.
/// </summary>
public sealed class AnthropicProvider : ILLMProvider
{
    private const string Url = "https://api.anthropic.com/v1/messages";
    private const int MaxTokens = 8192;
    private static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };

    public async IAsyncEnumerable<ProviderEvent> StreamTurnAsync(
        string system, IReadOnlyList<ChatTurn> turns, IReadOnlyList<ToolSpec> tools,
        string model, string apiKey, [EnumeratorCancellation] CancellationToken ct)
    {
        var body = new JsonObject
        {
            ["model"] = model,
            ["max_tokens"] = MaxTokens,
            ["system"] = system,
            ["stream"] = true,
            ["messages"] = WireMessages(turns),
        };
        if (tools.Count > 0)
            body["tools"] = new JsonArray(tools.Select(t => (JsonNode)new JsonObject
            {
                ["name"] = t.Name,
                ["description"] = t.Description,
                ["input_schema"] = t.InputSchema.DeepClone(),
            }).ToArray());

        using var req = new HttpRequestMessage(HttpMethod.Post, Url);
        req.Headers.Add("x-api-key", apiKey);
        req.Headers.Add("anthropic-version", "2023-06-01");
        req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

        using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!resp.IsSuccessStatusCode)
        {
            var err = await resp.Content.ReadAsStringAsync(ct);
            throw new InvalidOperationException($"Anthropic {(int)resp.StatusCode}: {Truncate(err, 500)}");
        }

        await using var stream = await resp.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream);

        var blocks = new SortedDictionary<int, BlockBuilder>();
        var stopReason = "end_turn";

        while (!reader.EndOfStream)
        {
            ct.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(ct);
            if (line is null) break;
            if (!line.StartsWith("data: ")) continue;

            var payload = line[6..].Trim();
            if (payload.Length == 0 || payload == "[DONE]") continue;

            JsonObject obj;
            try { obj = JsonNode.Parse(payload)!.AsObject(); } catch { continue; }
            var type = (string?)obj["type"];

            switch (type)
            {
                case "message_start":
                    if (obj["message"]?["usage"]?["input_tokens"] is JsonNode inTok)
                    {
                        var cacheRead = (int?)obj["message"]?["usage"]?["cache_read_input_tokens"] ?? 0;
                        var cacheWrite = (int?)obj["message"]?["usage"]?["cache_creation_input_tokens"] ?? 0;
                        yield return new ProviderEvent.Usage((int)inTok! + cacheRead + cacheWrite, 0);
                    }
                    break;

                case "content_block_start":
                {
                    var idx = (int?)obj["index"] ?? 0;
                    var cb = obj["content_block"]?.AsObject();
                    var bType = (string?)cb?["type"] ?? "text";
                    var b = new BlockBuilder { Kind = bType };
                    if (bType == "tool_use")
                    {
                        b.Id = (string?)cb!["id"] ?? "";
                        b.Name = (string?)cb["name"] ?? "";
                        yield return new ProviderEvent.ToolUseStarted(b.Id, b.Name);
                    }
                    blocks[idx] = b;
                    break;
                }

                case "content_block_delta":
                {
                    var idx = (int?)obj["index"] ?? 0;
                    if (!blocks.TryGetValue(idx, out var b)) { b = new BlockBuilder(); blocks[idx] = b; }
                    var delta = obj["delta"]?.AsObject();
                    var dType = (string?)delta?["type"];
                    if (dType == "text_delta")
                    {
                        var piece = (string?)delta!["text"] ?? "";
                        b.Text.Append(piece);
                        yield return new ProviderEvent.TextDelta(piece);
                    }
                    else if (dType == "input_json_delta")
                    {
                        var piece = (string?)delta!["partial_json"] ?? "";
                        b.Json.Append(piece);
                        yield return new ProviderEvent.ToolInputDelta(piece);
                    }
                    break;
                }

                case "message_delta":
                    stopReason = (string?)obj["delta"]?["stop_reason"] ?? stopReason;
                    if ((int?)obj["usage"]?["output_tokens"] is int outTok)
                        yield return new ProviderEvent.Usage(0, outTok);
                    break;

                case "message_stop":
                    goto done;
            }
        }

    done:
        yield return new ProviderEvent.TurnCompleted(blocks.Values.Select(b => b.Build()).ToList(), stopReason);
    }

    private static JsonArray WireMessages(IReadOnlyList<ChatTurn> turns)
    {
        var arr = new JsonArray();
        foreach (var turn in turns)
        {
            var content = new JsonArray();
            foreach (var block in turn.Blocks)
            {
                switch (block)
                {
                    case ContentBlock.Text t when t.Value.Length > 0:
                        content.Add(new JsonObject { ["type"] = "text", ["text"] = t.Value });
                        break;
                    case ContentBlock.Image img:
                        content.Add(new JsonObject
                        {
                            ["type"] = "image",
                            ["source"] = new JsonObject { ["type"] = "base64", ["media_type"] = img.Payload.MediaType, ["data"] = img.Payload.Base64 },
                        });
                        break;
                    case ContentBlock.ToolUse u:
                        content.Add(new JsonObject
                        {
                            ["type"] = "tool_use",
                            ["id"] = u.Id,
                            ["name"] = u.Name,
                            ["input"] = JsonNode.Parse(string.IsNullOrWhiteSpace(u.InputJson) ? "{}" : u.InputJson),
                        });
                        break;
                    case ContentBlock.ToolResult r:
                    {
                        var resultContent = new JsonArray { new JsonObject { ["type"] = "text", ["text"] = r.Content } };
                        foreach (var im in r.Images)
                            resultContent.Add(new JsonObject
                            {
                                ["type"] = "image",
                                ["source"] = new JsonObject { ["type"] = "base64", ["media_type"] = im.MediaType, ["data"] = im.Base64 },
                            });
                        content.Add(new JsonObject
                        {
                            ["type"] = "tool_result",
                            ["tool_use_id"] = r.ToolUseId,
                            ["is_error"] = r.IsError,
                            ["content"] = resultContent,
                        });
                        break;
                    }
                }
            }
            if (content.Count == 0) continue;
            arr.Add(new JsonObject { ["role"] = turn.Role == Role.User ? "user" : "assistant", ["content"] = content });
        }
        return arr;
    }

    private static string Truncate(string s, int n) => s.Length <= n ? s : s[..n];

    private sealed class BlockBuilder
    {
        public string Kind = "text";
        public string Id = "";
        public string Name = "";
        public StringBuilder Text = new();
        public StringBuilder Json = new();

        public ContentBlock Build() => Kind == "tool_use"
            ? new ContentBlock.ToolUse(Id, Name, Json.Length == 0 ? "{}" : Json.ToString())
            : new ContentBlock.Text(Text.ToString());
    }
}
