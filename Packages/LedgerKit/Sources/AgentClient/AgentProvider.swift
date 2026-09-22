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
}

public protocol AgentProvider: Sendable {
    func stream(system: String, turns: [ChatTurn]) -> AsyncThrowingStream<String, Error>
}

public enum AgentError: Error, Sendable {
    case http(status: Int, body: String)
    case invalidResponse
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

    static func stream(request: URLRequest, textDelta: @escaping @Sendable (SSEEvent) throws -> StreamStep) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await lines(for: request)
                    var parser = SSEParser()
                    var splitter = LineSplitter()
                    for try await byte in bytes {
                        guard let line = splitter.feed(byte), let event = parser.feed(line) else { continue }
                        switch try textDelta(event) {
                        case .text(let text): continuation.yield(text)
                        case .ignore: continue
                        case .done: continuation.finish(); return
                        }
                    }
                    if let line = splitter.flush(), let event = parser.feed(line), case .text(let text) = try textDelta(event) { continuation.yield(text) }
                    if let event = parser.flush(), case .text(let text) = try textDelta(event) { continuation.yield(text) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum StreamStep {
    case text(String)
    case ignore
    case done
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
