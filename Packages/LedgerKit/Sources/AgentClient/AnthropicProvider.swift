import Foundation

public struct AnthropicProvider: AgentProvider {
    public static let defaultModel = "claude-opus-5"
    public var apiKey: String
    public var model: String
    public var baseURL: URL

    public init(apiKey: String, model: String = defaultModel, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }

    public func stream(system: String, turns: [ChatTurn], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        var request = URLRequest(url: baseURL.appending(path: "v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "system": system,
            "messages": ChatTurn.merged(turns).map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schemaObject] }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return HTTPStreaming.stream(request: request, decoder: Decoder.self)
    }

    struct Decoder: StreamDecoder {
        private var pending: [Int: ToolCall] = [:]

        mutating func decode(_ event: SSEEvent) throws -> StreamStep {
            guard let json = try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
                  let type = json["type"] as? String else { throw AgentError.invalidResponse }
            let index = json["index"] as? Int ?? 0
            switch type {
            case "content_block_start":
                if let block = json["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
                   let id = block["id"] as? String, let name = block["name"] as? String {
                    pending[index] = ToolCall(id: id, name: name, arguments: "")
                }
                return .emit([])
            case "content_block_delta":
                guard let delta = json["delta"] as? [String: Any] else { return .emit([]) }
                switch delta["type"] as? String {
                case "text_delta":
                    return .emit((delta["text"] as? String).map { [.text($0)] } ?? [])
                case "input_json_delta":
                    pending[index]?.arguments += delta["partial_json"] as? String ?? ""
                    return .emit([])
                default:
                    return .emit([])
                }
            case "content_block_stop":
                guard let call = pending.removeValue(forKey: index) else { return .emit([]) }
                return .emit([.toolCall(call)])
            case "message_stop":
                return .done
            case "error":
                let message = (json["error"] as? [String: Any])?["message"] as? String ?? event.data
                throw AgentError.http(status: 0, body: message)
            default:
                return .emit([])
            }
        }

        mutating func finish() -> [AgentEvent] { [] }
    }
}
