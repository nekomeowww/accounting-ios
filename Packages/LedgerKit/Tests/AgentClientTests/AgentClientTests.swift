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

private func event(_ data: String) -> SSEEvent { SSEEvent(event: nil, data: data) }

@Test func anthropicMapsTextDeltasAndStops() throws {
    var decoder = AnthropicProvider.Decoder()
    #expect(try decoder.decode(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#)) == .emit([.text("Hi")]))
    #expect(try decoder.decode(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"…"}}"#)) == .emit([]))
    #expect(try decoder.decode(event(#"{"type":"message_stop"}"#)) == .done)
    #expect(throws: AgentError.self) {
        try decoder.decode(event(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
    }
}

@Test func anthropicAccumulatesToolInput() throws {
    var decoder = AnthropicProvider.Decoder()
    _ = try decoder.decode(event(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"propose_expense","input":{}}}"#))
    _ = try decoder.decode(event(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"amount\": "}}"#))
    _ = try decoder.decode(event(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"9700\"}"}}"#))
    let step = try decoder.decode(event(#"{"type":"content_block_stop","index":1}"#))
    #expect(step == .emit([.toolCall(ToolCall(id: "toolu_1", name: "propose_expense", arguments: #"{"amount": "9700"}"#))]))
    #expect(try decoder.decode(event(#"{"type":"content_block_stop","index":0}"#)) == .emit([]))
}

@Test func openAIMapsDeltaContentAndDone() throws {
    var decoder = OpenAICompatibleProvider.Decoder()
    #expect(try decoder.decode(event(#"{"choices":[{"delta":{"content":"Hey"},"index":0}]}"#)) == .emit([.text("Hey")]))
    #expect(try decoder.decode(event(#"{"choices":[{"delta":{"role":"assistant"},"index":0,"finish_reason":null}]}"#)) == .emit([]))
    #expect(try decoder.decode(event("[DONE]")) == .done)
}

@Test func openAIAccumulatesToolCallsUntilFinish() throws {
    var decoder = OpenAICompatibleProvider.Decoder()
    _ = try decoder.decode(event(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"propose_expense","arguments":""}}]}}]}"#))
    _ = try decoder.decode(event(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"amount\":"}}]}}]}"#))
    _ = try decoder.decode(event(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"12.50\"}"}}]}}]}"#))
    let step = try decoder.decode(event(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#))
    #expect(step == .emit([.toolCall(ToolCall(id: "call_1", name: "propose_expense", arguments: #"{"amount":"12.50"}"#))]))
    #expect(decoder.finish().isEmpty)
}

@Test func mergesConsecutiveSameRoleTurns() {
    let merged = ChatTurn.merged([ChatTurn(role: .user, text: "a"), ChatTurn(role: .assistant, text: "b"), ChatTurn(role: .assistant, text: "c")])
    #expect(merged == [ChatTurn(role: .user, text: "a"), ChatTurn(role: .assistant, text: "b\n\nc")])
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
