import Foundation

/// OpenAI Chat Completions client with SSE streaming + function calling,
/// mapped onto the same neutral ChatTurn/ContentBlock model.
/// Also serves Ollama (and any other OpenAI-compatible local server) by
/// pointing `endpoint` elsewhere and dropping the key requirement.
struct OpenAIProvider: LLMProvider {
    var endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    var requiresKey = true

    func streamTurn(
        system: String,
        turns: [ChatTurn],
        tools: [ToolSpec],
        model: String,
        apiKey: String
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(
                        system: system, turns: turns, tools: tools,
                        model: model, apiKey: apiKey, continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        turns: [ChatTurn],
        tools: [ToolSpec],
        model: String,
        apiKey: String,
        continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async throws {
        if requiresKey && apiKey.isEmpty { throw ProviderError.missingAPIKey }

        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in turns {
            messages.append(contentsOf: wireMessages(turn))
        }

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true], // emit a final usage chunk
            "messages": messages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map {
                [
                    "type": "function",
                    "function": [
                        "name": $0.name,
                        "description": $0.description,
                        "parameters": $0.inputSchema,
                    ],
                ]
            }
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = JSON.encode(body)
        request.timeoutInterval = 600

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformed("no HTTP response")
        }
        if http.statusCode != 200 {
            var errBody = ""
            for try await line in bytes.lines { errBody += line }
            throw ProviderError.http(http.statusCode, errBody)
        }

        var text = ""
        var toolCalls: [Int: (id: String, name: String, args: String)] = [:]
        var finishReason = "stop"
        var announced: Set<Int> = []

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let chunk = JSON.decode(payload) else { continue }
            // The final chunk (include_usage) has empty choices but a usage object.
            if let usage = chunk["usage"] as? [String: Any] {
                continuation.yield(.usage(
                    inputTokens: usage["prompt_tokens"] as? Int ?? 0,
                    outputTokens: usage["completion_tokens"] as? Int ?? 0
                ))
            }
            guard let choices = chunk["choices"] as? [[String: Any]],
                  let choice = choices.first else { continue }

            if let reason = choice["finish_reason"] as? String {
                finishReason = reason
            }
            guard let delta = choice["delta"] as? [String: Any] else { continue }

            if let piece = delta["content"] as? String, !piece.isEmpty {
                text += piece
                continuation.yield(.textDelta(piece))
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let index = call["index"] as? Int ?? 0
                    var entry = toolCalls[index] ?? (id: "", name: "", args: "")
                    if let id = call["id"] as? String { entry.id = id }
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String { entry.name += name }
                        if let args = function["arguments"] as? String {
                            entry.args += args
                            continuation.yield(.toolInputDelta(args))
                        }
                    }
                    toolCalls[index] = entry
                    if !announced.contains(index), !entry.name.isEmpty {
                        announced.insert(index)
                        continuation.yield(.toolUseStarted(id: entry.id, name: entry.name))
                    }
                }
            }
        }

        var blocks: [ContentBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        for index in toolCalls.keys.sorted() {
            let call = toolCalls[index]!
            blocks.append(.toolUse(
                id: call.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : call.id,
                name: call.name,
                inputJSON: call.args.isEmpty ? "{}" : call.args
            ))
        }
        let stopReason = finishReason == "tool_calls" ? "tool_use" : "end_turn"
        continuation.yield(.turnCompleted(blocks: blocks, stopReason: stopReason))
    }

    private func wireMessages(_ turn: ChatTurn) -> [[String: Any]] {
        switch turn.role {
        case .assistant:
            var content = ""
            var calls: [[String: Any]] = []
            for block in turn.blocks {
                switch block {
                case .text(let t): content += t
                case .toolUse(let id, let name, let inputJSON):
                    calls.append([
                        "id": id,
                        "type": "function",
                        "function": ["name": name, "arguments": inputJSON],
                    ])
                case .toolResult, .image: break
                }
            }
            var msg: [String: Any] = ["role": "assistant"]
            msg["content"] = content.isEmpty ? NSNull() : content
            if !calls.isEmpty { msg["tool_calls"] = calls }
            return [msg]

        case .user:
            // A "user" turn is either real user text or a batch of tool results.
            var results: [[String: Any]] = []
            var imageParts: [[String: Any]] = []
            var attachedImageParts: [[String: Any]] = []
            var content = ""
            for block in turn.blocks {
                switch block {
                case .text(let t): content += t
                case .image(let img):
                    attachedImageParts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(img.mediaType);base64,\(img.base64)"],
                    ])
                case .toolResult(let toolUseId, let result, _, let images):
                    results.append(["role": "tool", "tool_call_id": toolUseId, "content": result])
                    // OpenAI tool messages are text-only; images ride in a
                    // follow-up user message as data URLs.
                    for image in images {
                        imageParts.append([
                            "type": "image_url",
                            "image_url": ["url": "data:\(image.mediaType);base64,\(image.base64)"],
                        ])
                    }
                case .toolUse: break
                }
            }
            if !results.isEmpty {
                if !imageParts.isEmpty {
                    var parts: [[String: Any]] = [["type": "text", "text": "[image from the tool call above]"]]
                    parts.append(contentsOf: imageParts)
                    results.append(["role": "user", "content": parts])
                }
                return results
            }
            // Real user turn: text + any drag-and-dropped images.
            if !attachedImageParts.isEmpty {
                var parts: [[String: Any]] = []
                if !content.isEmpty { parts.append(["type": "text", "text": content]) }
                parts.append(contentsOf: attachedImageParts)
                return [["role": "user", "content": parts]]
            }
            return [["role": "user", "content": content]]
        }
    }
}
