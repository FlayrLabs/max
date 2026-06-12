import Foundation

// MARK: - Conversation model (provider-neutral, closely mirrors Anthropic Messages)

enum Role: String, Codable {
    case user
    case assistant
}

/// A base64 image travelling through the conversation (e.g. a screenshot).
struct ImagePayload: Codable, Equatable {
    let base64: String
    let mediaType: String // "image/jpeg" | "image/png"
}

enum ContentBlock: Codable, Equatable {
    case text(String)
    case image(ImagePayload)   // user-attached image (drag & drop)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseId: String, content: String, isError: Bool, images: [ImagePayload])

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, inputJSON, toolUseId, content, isError, images, image
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "image":
            self = .image(try c.decode(ImagePayload.self, forKey: .image))
        case "tool_use":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                inputJSON: try c.decode(String.self, forKey: .inputJSON)
            )
        case "tool_result":
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                content: try c.decode(String.self, forKey: .content),
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false,
                images: try c.decodeIfPresent([ImagePayload].self, forKey: .images) ?? []
            )
        default:
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .image(let payload):
            try c.encode("image", forKey: .type)
            try c.encode(payload, forKey: .image)
        case .toolUse(let id, let name, let inputJSON):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(inputJSON, forKey: .inputJSON)
        case .toolResult(let toolUseId, let content, let isError, let images):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseId, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .isError)
            if !images.isEmpty { try c.encode(images, forKey: .images) }
        }
    }
}

struct ChatTurn: Codable, Equatable {
    var role: Role
    var blocks: [ContentBlock]
}

// MARK: - Tool specs

struct ToolSpec {
    let name: String
    let description: String
    /// JSON Schema for the tool input, as a JSON object.
    let inputSchema: [String: Any]
}

// MARK: - Provider streaming events

enum ProviderEvent {
    case textDelta(String)
    case toolUseStarted(id: String, name: String)
    case toolInputDelta(String)
    case turnCompleted(blocks: [ContentBlock], stopReason: String)
    case usage(inputTokens: Int, outputTokens: Int)
}

enum ProviderError: LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key set. Open Settings and add one."
        case .http(let code, let body):
            return "API error \(code): \(body.prefix(400))"
        case .malformed(let why):
            return "Bad response from the model API: \(why)"
        }
    }
}

protocol LLMProvider {
    func streamTurn(
        system: String,
        turns: [ChatTurn],
        tools: [ToolSpec],
        model: String,
        apiKey: String
    ) -> AsyncThrowingStream<ProviderEvent, Error>
}

// MARK: - Agent events (what the UI consumes)

enum AgentEvent {
    case textDelta(String)
    case toolStarted(name: String, summary: String)
    case toolFinished(name: String, resultPreview: String, isError: Bool)
    case turnEnded(finalText: String)
    case failed(String)
}

// MARK: - JSON helpers

enum JSON {
    static func encode(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
    static func encodeString(_ obj: Any) -> String {
        String(data: encode(obj), encoding: .utf8) ?? "{}"
    }
    static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func decode(_ string: String) -> [String: Any]? {
        decode(Data(string.utf8))
    }
}
