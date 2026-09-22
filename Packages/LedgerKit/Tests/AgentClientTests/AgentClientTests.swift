import Testing
@testable import AgentClient

@Test func sseParserJoinsMultilineDataAndSkipsComments() {
    var parser = SSEParser()
    #expect(parser.feed(": keepalive") == nil)
    #expect(parser.feed("event: ping") == nil)
    #expect(parser.feed("data: a") == nil)
    #expect(parser.feed("data:b") == nil)
    #expect(parser.feed("") == SSEEvent(event: "ping", data: "a\nb"))
    #expect(parser.feed("") == nil)
    #expect(parser.feed("data: tail") == nil)
    #expect(parser.flush() == SSEEvent(event: nil, data: "tail"))
}

@Test func anthropicMapsTextDeltasAndStops() throws {
    let delta = SSEEvent(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#)
    guard case .text("Hi") = try AnthropicProvider.step(delta) else { Issue.record("expected text"); return }
    let thinking = SSEEvent(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"…"}}"#)
    guard case .ignore = try AnthropicProvider.step(thinking) else { Issue.record("expected ignore"); return }
    guard case .done = try AnthropicProvider.step(SSEEvent(event: "message_stop", data: #"{"type":"message_stop"}"#)) else { Issue.record("expected done"); return }
    #expect(throws: AgentError.self) {
        try AnthropicProvider.step(SSEEvent(event: "error", data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
    }
}

@Test func openAIMapsDeltaContentAndDone() throws {
    let delta = SSEEvent(event: nil, data: #"{"choices":[{"delta":{"content":"Hey"},"index":0}]}"#)
    guard case .text("Hey") = try OpenAICompatibleProvider.step(delta) else { Issue.record("expected text"); return }
    let roleOnly = SSEEvent(event: nil, data: #"{"choices":[{"delta":{"role":"assistant"},"index":0}]}"#)
    guard case .ignore = try OpenAICompatibleProvider.step(roleOnly) else { Issue.record("expected ignore"); return }
    guard case .done = try OpenAICompatibleProvider.step(SSEEvent(event: nil, data: "[DONE]")) else { Issue.record("expected done"); return }
}

@Test func lineSplitterKeepsBlankLinesAndStripsCR() {
    var splitter = LineSplitter()
    var lines: [String] = []
    for byte in Array("data: a\r\n\ndata: b\n".utf8) {
        if let line = splitter.feed(byte) { lines.append(line) }
    }
    if let tail = splitter.flush() { lines.append(tail) }
    #expect(lines == ["data: a", "", "data: b"])
}
