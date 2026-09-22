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

    public func stream(system: String, turns: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: baseURL.appending(path: "v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "system": system,
            "messages": turns.map { ["role": $0.role.rawValue, "content": $0.text] },
        ] as [String: Any])
        return HTTPStreaming.stream(request: request, textDelta: Self.step)
    }

    static func step(_ event: SSEEvent) throws -> StreamStep {
        guard let json = try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
              let type = json["type"] as? String else { throw AgentError.invalidResponse }
        switch type {
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return .ignore }
            return .text(text)
        case "message_stop":
            return .done
        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? event.data
            throw AgentError.http(status: 0, body: message)
        default:
            return .ignore
        }
    }
}
