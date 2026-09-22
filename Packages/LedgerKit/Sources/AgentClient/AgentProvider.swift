import Foundation

public enum ChatRole: String, Sendable, Codable {
    case user, assistant
}

public struct ChatTurn: Hashable, Sendable {
    public var role: ChatRole
    public var text: String

    public init(role: ChatRole, text: String) {
        self.role = role
        self.text = text
    }

    public static func merged(_ turns: [ChatTurn]) -> [ChatTurn] {
        turns.reduce(into: []) { result, turn in
            if result.last?.role == turn.role {
                result[result.count - 1].text += "\n\n" + turn.text
            } else {
                result.append(turn)
            }
        }
    }
}

public struct ToolSpec: Sendable {
    public var name: String
    public var description: String
    public var inputSchema: String

    public init(name: String, description: String, inputSchema: String) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    var schemaObject: Any {
        (try? JSONSerialization.jsonObject(with: Data(inputSchema.utf8))) ?? [String: Any]()
    }
}

public struct ToolCall: Hashable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum AgentEvent: Hashable, Sendable {
    case text(String)
    case toolCall(ToolCall)
}

public protocol AgentProvider: Sendable {
    func stream(system: String, turns: [ChatTurn], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error>
}

public enum AgentError: Error, Sendable {
    case http(status: Int, body: String)
    case invalidResponse
}

enum StreamStep: Equatable {
    case emit([AgentEvent])
    case done
}

protocol StreamDecoder: Sendable {
    init()
    mutating func decode(_ event: SSEEvent) throws -> StreamStep
    mutating func finish() -> [AgentEvent]
}

enum HTTPStreaming {
    static func lines(for request: URLRequest) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AgentError.http(status: http.statusCode, body: body)
        }
        return bytes
    }

    static func stream<Decoder: StreamDecoder>(request: URLRequest, decoder _: Decoder.Type) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await lines(for: request)
                    var parser = SSEParser()
                    var splitter = LineSplitter()
                    var decoder = Decoder()
                    func handle(_ event: SSEEvent) throws -> Bool {
                        switch try decoder.decode(event) {
                        case .emit(let events):
                            events.forEach { continuation.yield($0) }
                            return false
                        case .done:
                            return true
                        }
                    }
                    var finished = false
                    for try await byte in bytes {
                        guard let line = splitter.feed(byte), let event = parser.feed(line) else { continue }
                        if try handle(event) { finished = true; break }
                    }
                    if !finished {
                        if let line = splitter.flush(), let event = parser.feed(line) { _ = try handle(event) }
                        if let event = parser.flush() { _ = try handle(event) }
                    }
                    decoder.finish().forEach { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct LineSplitter {
    private var buffer: [UInt8] = []

    mutating func feed(_ byte: UInt8) -> String? {
        guard byte == UInt8(ascii: "\n") else {
            buffer.append(byte)
            return nil
        }
        return flush() ?? ""
    }

    mutating func flush() -> String? {
        defer { buffer.removeAll(keepingCapacity: true) }
        if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
        guard !buffer.isEmpty else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
}
