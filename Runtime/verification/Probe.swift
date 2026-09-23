import Foundation

private func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
}

private actor Evidence {
    var entries: [[String: Any]] = []
    var text = ""
    var tools = 0
    var runtime: PiAgentRuntime?
    var cancelOnText = false
    var failCheckpoint = false
    var closeOnTool = false
    var toolCancelled = false

    func attach(_ runtime: PiAgentRuntime, cancelOnText: Bool = false, failCheckpoint: Bool = false) {
        self.runtime = runtime; self.cancelOnText = cancelOnText; self.failCheckpoint = failCheckpoint
    }
    func detach() { runtime?.close(); runtime = nil }
    func closeDuringTool() { closeOnTool = true }
    func handle(_ operation: String, _ payload: String) async throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
        switch operation {
        case "checkpoint":
            let entry = object["entry"] as! [String: Any]
            if failCheckpoint && (entry["message"] as? [String: Any])?["role"] as? String == "assistant" {
                throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])
            }
            entries.append(entry)
        case "tool":
            precondition((entries.last?["message"] as? [String: Any])?["role"] as? String == "assistant")
            precondition(entries.last?["id"] as? String == object["messageId"] as? String)
            tools += 1
            if closeOnTool {
                runtime?.close()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { toolCancelled = true; throw error }
                preconditionFailure("Native tool was not cancelled on close")
            }
            try await Task.sleep(for: .milliseconds(5))
            return try json(["content": [["type": "text", "text": "pending_confirmation 東京"]], "details": ["proposalId": "p1"]])
        case "event":
            if object["type"] as? String == "text" {
                text += object["delta"] as? String ?? ""
                if cancelOnText { runtime?.abort(id: object["runId"] as! String) }
            }
        default: preconditionFailure("Unknown bridge operation")
        }
        return "null"
    }
    func checkpointJSON() throws -> String {
        let index = entries.lastIndex { ($0["message"] as? [String: Any])?["role"] as? String == "toolResult" }!
        return try json(Array(entries.prefix(index + 1)))
    }
    func assertSuccess(toolCount: Int) {
        precondition(tools == toolCount, "wrong tool execution count")
        precondition(text.contains("東京"), "lost streamed Unicode")
    }
    func assertCancelled() { precondition(text == "waiting", "received late output after cancellation: \(text)") }
    func assertNoTools() { precondition(tools == 0, "executed tool before durable checkpoint") }
    func assertToolCancelled() async {
        // Yield until the cancelled host Task has processed cancellation.
        for _ in 0..<100 {
            if toolCancelled { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Native tool Task leaked after close")
    }
}

@main struct Probe {
    static func main() async throws {
        let script = URL(fileURLWithPath: CommandLine.arguments[1])
        let base = CommandLine.arguments[2]
        func configuration(_ path: String = "/v1", anthropic: Bool = false, history: String = "[]") throws -> String {
            try json([
                "conversationId": UUID().uuidString, "systemPrompt": "Propose, then wait for confirmation.", "apiKey": "fixture-secret",
                "model": ["id": "fixture", "name": "fixture", "provider": anthropic ? "anthropic" : "openai",
                          "api": anthropic ? "anthropic-messages" : "openai-completions", "baseUrl": base + path,
                          "reasoning": false, "input": ["text"], "contextWindow": 4096, "maxTokens": 256,
                          "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]],
                "tools": [["name": "propose_expense", "label": "记账", "description": "Create proposal",
                           "parameters": ["type": "object", "properties": ["amount": ["type": "string"]], "required": ["amount"]]]],
                "history": try JSONSerialization.jsonObject(with: Data(history.utf8)),
            ])
        }
        func input() throws -> String { try json(["id": UUID().uuidString, "message": ["role": "user", "content": "晚饭 12.50", "timestamp": 1]]) }
        func status(_ result: String) throws -> String { (try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any])["status"] as! String }

        let evidence = Evidence()
        let first = try PiAgentRuntime(configurationJSON: configuration(), scriptURL: script, handler: evidence.handle)
        await evidence.attach(first)
        let firstResult = try await first.run(id: "first", inputJSON: input())
        let firstStatus = try status(firstResult)
        precondition(firstStatus == "complete", firstResult)
        await evidence.assertSuccess(toolCount: 1)
        let checkpoint = try await evidence.checkpointJSON()
        await evidence.detach()
        let restoredEvidence = Evidence()
        let restored = try PiAgentRuntime(configurationJSON: configuration(history: checkpoint), scriptURL: script, handler: restoredEvidence.handle)
        await restoredEvidence.attach(restored)
        let restoredStatus = try await status(restored.run(id: "restored"))
        precondition(restoredStatus == "complete")
        await restoredEvidence.assertSuccess(toolCount: 0)
        await restoredEvidence.detach()

        for (path, anthropic, expected) in [("/anthropic", true, "complete"), ("/unauthorized", false, "failed"), ("/redirect", false, "failed"), ("/slow", false, "aborted")] {
            let evidence = Evidence()
            let runtime = try PiAgentRuntime(configurationJSON: configuration(path, anthropic: anthropic), scriptURL: script, handler: evidence.handle)
            await evidence.attach(runtime, cancelOnText: path == "/slow")
            let result = try await runtime.run(id: path, inputJSON: input())
            let resultStatus = try status(result)
            precondition(resultStatus == expected, "\(path): \(result)")
            if path == "/unauthorized" { precondition(result.contains("invalid fixture credential"), "HTTP error body lost: \(result)") }
            if path == "/slow" { await evidence.assertCancelled() }
            if anthropic { await evidence.assertSuccess(toolCount: 0) }
            await evidence.detach()
        }

        let failed = Evidence()
        let runtime = try PiAgentRuntime(configurationJSON: configuration(), scriptURL: script, handler: failed.handle)
        await failed.attach(runtime, failCheckpoint: true)
        let failure = try await runtime.run(id: "disk-full", inputJSON: input())
        precondition(failure.contains("disk full"))
        await failed.assertNoTools()
        await failed.detach()
        let closing = Evidence()
        let closingRuntime = try PiAgentRuntime(configurationJSON: configuration(), scriptURL: script, handler: closing.handle)
        await closing.attach(closingRuntime)
        await closing.closeDuringTool()
        do {
            _ = try await closingRuntime.run(id: "close", inputJSON: input())
            preconditionFailure("Closing an active runtime must terminate the awaiting run")
        } catch { precondition(error.localizedDescription.contains("closed"), error.localizedDescription) }
        await closing.assertToolCancelled()
        await closing.detach()
        print("PASS: JSC, both pi providers, native HTTP/auth/error body, Swift tool, checkpoints, restore, cancellation, close cleanup, cross-origin redirect rejection")
    }
}
