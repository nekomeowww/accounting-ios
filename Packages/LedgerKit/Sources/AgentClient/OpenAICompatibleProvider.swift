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

    public func stream(system: String, turns: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        let messages = [["role": "system", "content": system]] + turns.map { ["role": $0.role.rawValue, "content": $0.text] }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "messages": messages,
        ] as [String: Any])
        return HTTPStreaming.stream(request: request, textDelta: Self.step)
    }

    static func step(_ event: SSEEvent) throws -> StreamStep {
        if event.data == "[DONE]" { return .done }
        guard let json = try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else { throw AgentError.invalidResponse }
        if let error = json["error"] as? [String: Any] {
            throw AgentError.http(status: 0, body: error["message"] as? String ?? event.data)
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any],
              let text = delta["content"] as? String, !text.isEmpty else { return .ignore }
        return .text(text)
    }
}
