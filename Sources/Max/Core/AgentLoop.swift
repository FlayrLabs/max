import Foundation
import AppKit

/// The agentic loop, ported from OpenClaw's agent-core design:
/// user message → LLM stream → execute tool calls → feed results back → repeat
/// until a turn produces no tool calls.
enum AgentLoop {

    static func makeRegistry(includeVision: Bool, devices: [RemoteDevice]) -> ToolRegistry {
        var tools: [MaxTool] = [
            ExecTool(),
            AppleScriptTool(),
            ReadFileTool(),
            WriteFileTool(),
            LoopTool(),
        ]
        if includeVision {
            tools.append(SeeScreenTool())
            tools.append(ReadScreenTextTool())
        }
        if !devices.isEmpty {
            tools.append(RemoteExecTool(devices: devices))
        }
        return ToolRegistry(tools)
    }

    /// Old screenshots cost full image tokens on every subsequent request.
    /// Keep only the newest `keep` image-bearing tool results on the wire;
    /// the JSONL transcript on disk keeps everything.
    static func pruneImages(_ turns: [ChatTurn], keep: Int = 2) -> [ChatTurn] {
        var imageTurnIndices: [Int] = []
        for (i, turn) in turns.enumerated() {
            if turn.blocks.contains(where: {
                if case .toolResult(_, _, _, let images) = $0 { return !images.isEmpty }
                return false
            }) {
                imageTurnIndices.append(i)
            }
        }
        let dropIndices = Set(imageTurnIndices.dropLast(keep))
        guard !dropIndices.isEmpty else { return turns }

        return turns.enumerated().map { i, turn in
            guard dropIndices.contains(i) else { return turn }
            var copy = turn
            copy.blocks = turn.blocks.map { block in
                if case .toolResult(let id, let content, let isError, let images) = block, !images.isEmpty {
                    return .toolResult(
                        toolUseId: id,
                        content: content + "\n[screenshot omitted from context — take a fresh one if needed]",
                        isError: isError,
                        images: []
                    )
                }
                return block
            }
            return copy
        }
    }

    static func provider(config: MaxConfig) -> LLMProvider {
        switch config.provider {
        case .anthropic:
            return AnthropicProvider()
        case .openai:
            return OpenAIProvider()
        case .ollama:
            var base = config.ollamaBaseURL.trimmingCharacters(in: .whitespaces)
            while base.hasSuffix("/") { base.removeLast() }
            let url = URL(string: "\(base)/v1/chat/completions")
                ?? URL(string: "http://127.0.0.1:11434/v1/chat/completions")!
            return OpenAIProvider(endpoint: url, requiresKey: false)
        }
    }

    /// Runs one full agentic exchange. Events stream back for the UI;
    /// the session transcript is appended as the loop progresses.
    static func run(
        session: ChatSession,
        userText: String,
        config: MaxConfig,
        isLoopRun: Bool = false,
        isRemoteOrigin: Bool = false
    ) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let task = Task {
                let includeVision = isLoopRun
                    ? (config.allowScreenVision && config.loopsCanSeeScreen)
                    : config.allowScreenVision
                let registry = makeRegistry(includeVision: includeVision, devices: config.devices)
                let llm = provider(config: config)
                let apiKey = SecretStore.apiKey(for: config.provider) ?? ""
                let system = SystemPrompt.build(
                    config: config, soul: Soul.load(), isLoopRun: isLoopRun, includeVision: includeVision
                )

                // Kill switch: when paused, no tool runs at all.
                if config.paused {
                    continuation.yield(.failed("Max is paused. Resume from the menu-bar icon to use it."))
                    continuation.finish()
                    return
                }
                // Spend cap.
                if SpendTracker.isOverLimit(config) {
                    let limit = String(format: "%.2f", config.dailySpendLimitUSD)
                    continuation.yield(.failed("Daily spend limit ($\(limit)) reached. Raise it in Settings → Spending."))
                    continuation.finish()
                    return
                }

                session.append(ChatTurn(role: .user, blocks: [.text(userText)]))

                var iterations = 0
                var finalText = ""

                loop: while iterations < 30 {
                    iterations += 1
                    var completed: (blocks: [ContentBlock], stopReason: String)?

                    do {
                        let stream = llm.streamTurn(
                            system: system,
                            turns: pruneImages(session.turns),
                            tools: registry.specs,
                            model: config.model,
                            apiKey: apiKey
                        )
                        for try await event in stream {
                            if Task.isCancelled { break loop }
                            switch event {
                            case .textDelta(let piece):
                                continuation.yield(.textDelta(piece))
                            case .turnCompleted(let blocks, let stopReason):
                                completed = (blocks, stopReason)
                            case .usage(let inputTokens, let outputTokens):
                                SpendTracker.record(model: config.model,
                                                    inputTokens: inputTokens, outputTokens: outputTokens)
                            case .toolUseStarted, .toolInputDelta:
                                break // surfaced after input JSON is complete
                            }
                        }
                    } catch {
                        continuation.yield(.failed(error.localizedDescription))
                        continuation.finish()
                        return
                    }

                    guard let turn = completed else {
                        continuation.yield(.failed("model stream ended unexpectedly"))
                        continuation.finish()
                        return
                    }

                    session.append(ChatTurn(role: .assistant, blocks: turn.blocks))
                    for case .text(let t) in turn.blocks { finalText = t }

                    let toolUses = turn.blocks.compactMap { block -> (String, String, String)? in
                        if case .toolUse(let id, let name, let inputJSON) = block {
                            return (id, name, inputJSON)
                        }
                        return nil
                    }

                    if turn.stopReason != "tool_use" || toolUses.isEmpty {
                        break loop
                    }

                    var results: [ContentBlock] = []
                    for (id, name, inputJSON) in toolUses {
                        if Task.isCancelled { break loop }
                        let input = JSON.decode(inputJSON) ?? [:]
                        guard let tool = registry.tool(named: name) else {
                            results.append(.toolResult(toolUseId: id, content: "unknown tool \(name)", isError: true, images: []))
                            continue
                        }
                        let summary = tool.summary(input: input)
                        continuation.yield(.toolStarted(name: name, summary: summary))

                        // Commands that act on the system need approval in ask
                        // mode — but only when a human is at the Mac (the desk
                        // session). Headless loop/channel runs can't show a
                        // dialog; the denylist is their safety net.
                        let needsApproval = ["exec", "applescript", "remote_exec"].contains(name)
                        if config.execApproval == .ask, !isLoopRun, !isRemoteOrigin, needsApproval {
                            let approved = await requestApproval(summary: summary)
                            if !approved {
                                ActionLog.write("DENIED \(name): \(summary)")
                                results.append(.toolResult(toolUseId: id, content: "User denied this command.", isError: true, images: []))
                                continuation.yield(.toolFinished(name: name, resultPreview: "denied", isError: true))
                                continue
                            }
                        }

                        let outcome = await tool.execute(input: input)
                        ActionLog.write("\(outcome.isError ? "ERROR" : "ran") \(name): \(summary)")
                        results.append(.toolResult(
                            toolUseId: id, content: outcome.content,
                            isError: outcome.isError, images: outcome.images
                        ))
                        continuation.yield(.toolFinished(
                            name: name,
                            resultPreview: String(outcome.content.prefix(200)),
                            isError: outcome.isError
                        ))
                    }
                    session.append(ChatTurn(role: .user, blocks: results))
                }

                continuation.yield(.turnEnded(finalText: finalText))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor
    private static func requestApproval(summary: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Max wants to run a command"
        alert.informativeText = summary
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
