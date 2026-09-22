import Foundation

public struct OpenAICompatibleProvider: AgentProvider {
    public static let defaultModel = "gpt-4o"
    public var baseURL: URL
    public var apiKey: String
    public var model: String

    public init(baseURL: URL, apiKey: String, model: String = defaultModel) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    public func stream(system: String, turns: [ChatTurn], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        let messages = [["role": "system", "content": system]] + ChatTurn.merged(turns).map { ["role": $0.role.rawValue, "content": $0.text] }
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schemaObject]] }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return HTTPStreaming.stream(request: request, decoder: Decoder.self)
    }

    struct Decoder: StreamDecoder {
        private var pending: [Int: ToolCall] = [:]

        mutating func decode(_ event: SSEEvent) throws -> StreamStep {
            if event.data == "[DONE]" { return .done }
            guard let json = try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else { throw AgentError.invalidResponse }
            if let error = json["error"] as? [String: Any] {
                throw AgentError.http(status: 0, body: error["message"] as? String ?? event.data)
            }
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { return .emit([]) }
            var events: [AgentEvent] = []
            if let delta = choice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty { events.append(.text(text)) }
                for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = fragment["index"] as? Int ?? 0
                    var call = pending[index] ?? ToolCall(id: "", name: "", arguments: "")
                    if let id = fragment["id"] as? String, !id.isEmpty { call.id = id }
                    let function = fragment["function"] as? [String: Any]
                    if let name = function?["name"] as? String, !name.isEmpty { call.name = name }
                    call.arguments += function?["arguments"] as? String ?? ""
                    pending[index] = call
                }
            }
            if choice["finish_reason"] is String { events += finish() }
            return .emit(events)
        }

        mutating func finish() -> [AgentEvent] {
            defer { pending.removeAll() }
            return pending.keys.sorted().compactMap { pending[$0] }.filter { !$0.name.isEmpty }.map { .toolCall($0) }
        }
    }
}
