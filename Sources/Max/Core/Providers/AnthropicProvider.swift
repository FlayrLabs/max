import Foundation

/// Raw Messages API client with SSE streaming + tool use.
/// POST https://api.anthropic.com/v1/messages
struct AnthropicProvider: LLMProvider {

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
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "system": system,
            "messages": repairedTurns(turns).map(wireMessage),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map {
                ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema]
            }
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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

        // Assemble content blocks by stream index.
        var blockTypes: [Int: String] = [:]          // index -> "text" | "tool_use"
        var textAcc: [Int: String] = [:]
        var toolIds: [Int: String] = [:]
        var toolNames: [Int: String] = [:]
        var toolJSONAcc: [Int: String] = [:]
        var order: [Int] = []
        var stopReason = "end_turn"
        var inputTokens = 0
        var outputTokens = 0

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let event = JSON.decode(payload),
                  let type = event["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                guard let index = event["index"] as? Int,
                      let block = event["content_block"] as? [String: Any],
                      let blockType = block["type"] as? String else { continue }
                blockTypes[index] = blockType
                order.append(index)
                if blockType == "tool_use" {
                    let id = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? "unknown"
                    toolIds[index] = id
                    toolNames[index] = name
                    toolJSONAcc[index] = ""
                    continuation.yield(.toolUseStarted(id: id, name: name))
                } else if blockType == "text" {
                    textAcc[index] = ""
                }

            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { continue }
                if deltaType == "text_delta", let text = delta["text"] as? String {
                    textAcc[index, default: ""] += text
                    continuation.yield(.textDelta(text))
                } else if deltaType == "input_json_delta", let part = delta["partial_json"] as? String {
                    toolJSONAcc[index, default: ""] += part
                    continuation.yield(.toolInputDelta(part))
                }

            case "message_start":
                if let message = event["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    inputTokens = (usage["input_tokens"] as? Int ?? 0)
                        + (usage["cache_read_input_tokens"] as? Int ?? 0)
                        + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                }

            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
                if let usage = event["usage"] as? [String: Any],
                   let out = usage["output_tokens"] as? Int {
                    outputTokens = out // cumulative for the message
                }

            case "message_stop":
                if inputTokens > 0 || outputTokens > 0 {
                    continuation.yield(.usage(inputTokens: inputTokens, outputTokens: outputTokens))
                }
                var blocks: [ContentBlock] = []
                for index in order {
                    switch blockTypes[index] {
                    case "text":
                        let text = textAcc[index] ?? ""
                        if !text.isEmpty { blocks.append(.text(text)) }
                    case "tool_use":
                        let json = toolJSONAcc[index].flatMap { $0.isEmpty ? "{}" : $0 } ?? "{}"
                        blocks.append(.toolUse(
                            id: toolIds[index] ?? UUID().uuidString,
                            name: toolNames[index] ?? "unknown",
                            inputJSON: json
                        ))
                    default:
                        break
                    }
                }
                continuation.yield(.turnCompleted(blocks: blocks, stopReason: stopReason))
                return

            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "unknown stream error"
                throw ProviderError.malformed(message)

            default:
                break // message_start, content_block_stop, ping
            }
        }
        throw ProviderError.malformed("stream ended without message_stop")
    }

    /// Repairs a turn list so it's always valid for the Messages API, even if a tool call
    /// was interrupted (Max quit mid-run, or a new message was sent before the tool finished).
    /// Without this, a dangling `tool_use` with no following `tool_result` makes the API
    /// reject the whole conversation ("tool_use ids were found without tool_result blocks"),
    /// wedging the chat permanently.
    private func repairedTurns(_ turns: [ChatTurn]) -> [ChatTurn] {
        // Pass 1: ensure every assistant tool_use has a matching user tool_result.
        var paired: [ChatTurn] = []
        var i = 0
        while i < turns.count {
            let turn = turns[i]
            paired.append(turn)
            let toolUseIds = turn.blocks.compactMap { block -> String? in
                if case .toolUse(let id, _, _) = block { return id }
                return nil
            }
            if !toolUseIds.isEmpty {
                let next = (i + 1 < turns.count && turns[i + 1].role == .user) ? turns[i + 1] : nil
                let provided = Set((next?.blocks ?? []).compactMap { block -> String? in
                    if case .toolResult(let id, _, _, _) = block { return id }
                    return nil
                })
                let synthetic = toolUseIds.filter { !provided.contains($0) }.map { id in
                    ContentBlock.toolResult(toolUseId: id,
                                            content: "Tool call was interrupted and produced no result.",
                                            isError: true, images: [])
                }
                if let next = next {
                    paired.append(ChatTurn(role: .user, blocks: synthetic + next.blocks))
                    i += 2
                    continue
                } else if !synthetic.isEmpty {
                    paired.append(ChatTurn(role: .user, blocks: synthetic))
                }
            }
            i += 1
        }
        // Pass 2: merge consecutive same-role turns (a stray retry can leave two in a row).
        var merged: [ChatTurn] = []
        for turn in paired {
            if let last = merged.last, last.role == turn.role {
                merged[merged.count - 1] = ChatTurn(role: last.role, blocks: last.blocks + turn.blocks)
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    private func wireMessage(_ turn: ChatTurn) -> [String: Any] {
        var content: [[String: Any]] = []
        for block in turn.blocks {
            switch block {
            case .text(let t):
                content.append(["type": "text", "text": t])
            case .image(let img):
                content.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": img.mediaType, "data": img.base64],
                ])
            case .toolUse(let id, let name, let inputJSON):
                content.append([
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": JSON.decode(inputJSON) ?? [:],
                ])
            case .toolResult(let toolUseId, let result, let isError, let images):
                if images.isEmpty {
                    content.append([
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": result,
                        "is_error": isError,
                    ])
                } else {
                    var parts: [[String: Any]] = [["type": "text", "text": result]]
                    for image in images {
                        parts.append([
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": image.mediaType,
                                "data": image.base64,
                            ],
                        ])
                    }
                    content.append([
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": parts,
                        "is_error": isError,
                    ])
                }
            }
        }
        return ["role": turn.role.rawValue, "content": content]
    }
}
