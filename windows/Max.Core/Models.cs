using System.Text.Json;
using System.Text.Json.Nodes;

namespace Max.Core;

/// <summary>Who authored a turn. Mirrors the macOS app's Role.</summary>
public enum Role { User, Assistant }

/// <summary>A base64 image travelling through the conversation (screenshot or attachment).</summary>
public sealed record ImagePayload(string Base64, string MediaType);

/// <summary>
/// One piece of message content. Modeled as a closed hierarchy so providers can
/// switch on the concrete type, exactly like the Swift ContentBlock enum.
/// </summary>
public abstract record ContentBlock
{
    public sealed record Text(string Value) : ContentBlock;
    public sealed record Image(ImagePayload Payload) : ContentBlock;
    public sealed record ToolUse(string Id, string Name, string InputJson) : ContentBlock;
    public sealed record ToolResult(string ToolUseId, string Content, bool IsError, IReadOnlyList<ImagePayload> Images) : ContentBlock;

    /// <summary>Our own on-disk wire shape (the JSONL transcript), not a provider's.</summary>
    public JsonObject ToNode() => this switch
    {
        Text t => new JsonObject { ["type"] = "text", ["text"] = t.Value },
        Image i => new JsonObject { ["type"] = "image", ["base64"] = i.Payload.Base64, ["mediaType"] = i.Payload.MediaType },
        ToolUse u => new JsonObject { ["type"] = "tool_use", ["id"] = u.Id, ["name"] = u.Name, ["inputJson"] = u.InputJson },
        ToolResult r => new JsonObject
        {
            ["type"] = "tool_result",
            ["toolUseId"] = r.ToolUseId,
            ["content"] = r.Content,
            ["isError"] = r.IsError,
            ["images"] = new JsonArray(r.Images.Select(im =>
                (JsonNode)new JsonObject { ["base64"] = im.Base64, ["mediaType"] = im.MediaType }).ToArray()),
        },
        _ => throw new InvalidOperationException("unknown block"),
    };

    public static ContentBlock FromNode(JsonNode node)
    {
        var o = node.AsObject();
        var type = (string?)o["type"] ?? "text";
        switch (type)
        {
            case "image":
                return new Image(new ImagePayload((string)o["base64"]!, (string)o["mediaType"]!));
            case "tool_use":
                return new ToolUse((string)o["id"]!, (string)o["name"]!, (string?)o["inputJson"] ?? "{}");
            case "tool_result":
                var images = (o["images"] as JsonArray ?? new JsonArray())
                    .Select(n => new ImagePayload((string)n!["base64"]!, (string)n!["mediaType"]!))
                    .ToList();
                return new ToolResult((string)o["toolUseId"]!, (string?)o["content"] ?? "",
                    (bool?)o["isError"] ?? false, images);
            default:
                return new Text((string?)o["text"] ?? "");
        }
    }
}

/// <summary>One conversational turn = a role plus its content blocks.</summary>
public sealed class ChatTurn
{
    public Role Role { get; init; }
    public List<ContentBlock> Blocks { get; init; }

    public ChatTurn(Role role, IEnumerable<ContentBlock> blocks)
    {
        Role = role;
        Blocks = blocks.ToList();
    }

    public string ToJsonLine()
    {
        var o = new JsonObject
        {
            ["role"] = Role == Role.User ? "user" : "assistant",
            ["blocks"] = new JsonArray(Blocks.Select(b => (JsonNode)b.ToNode()).ToArray()),
        };
        return o.ToJsonString();
    }

    public static ChatTurn FromJsonLine(string line)
    {
        var o = JsonNode.Parse(line)!.AsObject();
        var role = (string?)o["role"] == "assistant" ? Role.Assistant : Role.User;
        var blocks = (o["blocks"] as JsonArray ?? new JsonArray()).Select(n => ContentBlock.FromNode(n!));
        return new ChatTurn(role, blocks);
    }
}

/// <summary>A tool the model may call (name + description + JSON Schema for its input).</summary>
public sealed record ToolSpec(string Name, string Description, JsonObject InputSchema);

/// <summary>Streaming events emitted by an <see cref="ILLMProvider"/> during one turn.</summary>
public abstract record ProviderEvent
{
    public sealed record TextDelta(string Text) : ProviderEvent;
    public sealed record ToolUseStarted(string Id, string Name) : ProviderEvent;
    public sealed record ToolInputDelta(string Json) : ProviderEvent;
    public sealed record TurnCompleted(IReadOnlyList<ContentBlock> Blocks, string StopReason) : ProviderEvent;
    public sealed record Usage(int InputTokens, int OutputTokens) : ProviderEvent;
}

/// <summary>Higher-level events the UI consumes, emitted by the <see cref="AgentLoop"/>.</summary>
public abstract record AgentEvent
{
    public sealed record TextDelta(string Text) : AgentEvent;
    public sealed record ToolStarted(string Name, string Summary) : AgentEvent;
    public sealed record ToolFinished(string Name, string ResultPreview, bool IsError) : AgentEvent;
    public sealed record TurnEnded(string FinalText) : AgentEvent;
    public sealed record Failed(string Message) : AgentEvent;
}

/// <summary>An LLM backend that can stream one agentic turn (tool-use aware).</summary>
public interface ILLMProvider
{
    IAsyncEnumerable<ProviderEvent> StreamTurnAsync(
        string system,
        IReadOnlyList<ChatTurn> turns,
        IReadOnlyList<ToolSpec> tools,
        string model,
        string apiKey,
        CancellationToken ct);
}
