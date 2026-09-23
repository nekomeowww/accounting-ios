import Foundation
import JavaScriptCore

/// One runtime per conversation. The handler returns JSON and must commit checkpoints/tools before returning.
public final class PiAgentRuntime: Sendable {
    public typealias Handler = @Sendable (_ operation: String, _ payloadJSON: String) async throws -> String
    private let worker: PiRuntimeWorker

    public init(configurationJSON: String, scriptURL: URL? = nil, handler: @escaping Handler) throws {
        guard let scriptURL = scriptURL ?? Bundle.main.url(forResource: "agent", withExtension: "js", subdirectory: "AgentRuntime") else {
            throw PiRuntimeError.message("Agent runtime resource is missing; run the Runtime build phase")
        }
        worker = try PiRuntimeWorker(configurationJSON: configurationJSON, scriptURL: scriptURL, handler: handler)
    }

    /// nil input continues a restored transcript. A new input contains { id, message: { role, content, timestamp } }.
    public func run(id: String, inputJSON: String? = nil) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await worker.run(id: id, input: inputJSON ?? "")
        } onCancel: {
            worker.abort(id: id, pending: true)
        }
    }

    public func abort(id: String) { worker.abort(id: id) }
    public func close() { worker.close() }
    deinit { worker.close() }
}

private enum PiRuntimeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private func jsonString(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
}

private func origin(_ url: URL) -> String {
    let scheme = url.scheme?.lowercased() ?? ""
    return "\(scheme)://\(url.host?.lowercased() ?? ""):\(url.port ?? (scheme == "https" ? 443 : 80))"
}

private final class PiRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let allowedOrigin: String
    init(url: URL) { allowedOrigin = origin(url) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map { origin($0) == allowedOrigin } == true ? request : nil)
    }
}

/// Mutable state, including every JSValue, is confined to queue. Network/host tasks only send serialized replies.
private final class PiRuntimeWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.innei.Accounting.pi-jsc", qos: .userInitiated)
    private let handler: PiAgentRuntime.Handler
    private let allowedOrigin: String
    private let session: URLSession
    private var context: JSContext?
    private var runtime: JSValue?
    private var closed = false
    private var currentRun: (id: String, continuation: CheckedContinuation<String, any Error>)?
    private var cancelledRuns = Set<String>()
    private var calls: [Int: Task<Void, Never>] = [:]
    private var requests: [Int: Task<Void, Never>] = [:]
    private var credits: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var suspended: [Int: URLSessionDataTask] = [:]
    private var timers: [Int: DispatchWorkItem] = [:]

    init(configurationJSON: String, scriptURL: URL, handler: @escaping PiAgentRuntime.Handler) throws {
        self.handler = handler
        guard let data = configurationJSON.data(using: .utf8),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = config["model"] as? [String: Any], let base = model["baseUrl"] as? String,
              let url = URL(string: base), let host = url.host,
              url.user == nil, url.password == nil,
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)) else {
            throw PiRuntimeError.message("Provider requires HTTPS (HTTP is allowed only for loopback tests)")
        }
        allowedOrigin = origin(url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration, delegate: PiRedirectPolicy(url: url), delegateQueue: nil)
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        try queue.sync {
            do {
                try install(script: script, source: scriptURL)
                _ = try invoke("configure", [configurationJSON])
            } catch {
                shutdown(error)
                throw error
            }
        }
    }

    private func install(script: String, source: URL) throws {
        guard let js = JSContext() else { throw PiRuntimeError.message("Cannot create JavaScriptCore context") }
        context = js
        let call: @convention(block) (Int, String, String) -> Void = { [weak self] id, operation, payload in
            self?.startCall(id, operation: operation, payload: payload)
        }
        let cancelCall: @convention(block) (Int) -> Void = { [weak self] id in self?.calls.removeValue(forKey: id)?.cancel() }
        let fetch: @convention(block) (Int, String) -> Void = { [weak self] id, payload in self?.startHTTP(id, payload: payload) }
        let cancelHTTP: @convention(block) (Int) -> Void = { [weak self] id in self?.cancelHTTP(id) }
        let resumeHTTP: @convention(block) (Int) -> Void = { [weak self] id in
            self?.suspended.removeValue(forKey: id)?.resume()
            self?.credits.removeValue(forKey: id)?.resume()
        }
        let timer: @convention(block) (Int, Double) -> Void = { [weak self] id, milliseconds in
            guard let self else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.closed else { return }
                self.timers.removeValue(forKey: id)
                self.notify("fireTimer", [id])
            }
            self.timers[id] = item
            self.queue.asyncAfter(deadline: .now() + min(max(milliseconds, 0), 2_147_483_647) / 1000, execute: item)
        }
        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
        let encode: @convention(block) (String) -> [NSNumber] = { $0.utf8.map { NSNumber(value: $0) } }
        let decode: @convention(block) ([NSNumber], Bool) -> String? = { numbers, fatal in
            let bytes = numbers.map(\.uint8Value)
            return fatal ? String(bytes: bytes, encoding: .utf8) : String(decoding: bytes, as: UTF8.self)
        }
        let finish: @convention(block) (String, String) -> Void = { [weak self] id, json in
            guard let self, self.currentRun?.id == id else { return }
            let continuation = self.currentRun?.continuation
            self.currentRun = nil
            continuation?.resume(returning: json)
        }
        for (name, block) in [
            ("nativeCall", call as Any), ("nativeCancelCall", cancelCall as Any),
            ("nativeFetch", fetch as Any), ("nativeCancelHTTP", cancelHTTP as Any), ("nativeResumeHTTP", resumeHTTP as Any),
            ("nativeTimer", timer as Any), ("nativeClearTimer", clearTimer as Any),
            ("nativeEncode", encode as Any), ("nativeDecode", decode as Any), ("nativeFinish", finish as Any),
        ] { js.setObject(block, forKeyedSubscript: name as NSString) }
        js.evaluateScript(script, withSourceURL: source)
        if let exception = js.exception { throw PiRuntimeError.message(exception.toString() ?? "JS bootstrap failed") }
        runtime = js.objectForKeyedSubscript("AccountingAgent")
    }

    private func invoke(_ method: String, _ arguments: [Any]) throws -> JSValue? {
        guard !closed, let context, let runtime else { throw PiRuntimeError.message("Runtime closed") }
        context.exception = nil
        let result = runtime.invokeMethod(method, withArguments: arguments)
        if let exception = context.exception { throw PiRuntimeError.message(exception.toString() ?? "JavaScript error") }
        return result
    }

    private func notify(_ method: String, _ arguments: [Any]) {
        guard !closed else { return }
        do { _ = try invoke(method, arguments) } catch { shutdown(error) }
    }

    func run(id: String, input: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !closed else { continuation.resume(throwing: PiRuntimeError.message("Runtime closed")); return }
                guard currentRun == nil else { continuation.resume(throwing: PiRuntimeError.message("Conversation already running")); return }
                guard cancelledRuns.remove(id) == nil else { continuation.resume(throwing: CancellationError()); return }
                currentRun = (id, continuation)
                do { _ = try invoke("run", [id, input]) }
                catch { currentRun = nil; continuation.resume(throwing: error) }
            }
        }
    }

    func abort(id: String, pending: Bool = false) {
        queue.async { [self] in
            guard !closed else { return }
            if currentRun?.id == id { notify("abort", [id]) }
            else if pending { cancelledRuns.insert(id) }
        }
    }

    private func startCall(_ id: Int, operation: String, payload: String) {
        guard !closed else { return }
        let handler = handler
        calls[id] = Task { [weak self] in
            let success: Bool
            let json: String
            do {
                json = try await handler(operation, payload)
                success = true
            } catch {
                json = (try? jsonString(error.localizedDescription)) ?? "\"Host operation failed\""
                success = false
            }
            self?.queue.async { [weak self] in
                guard let self, self.calls.removeValue(forKey: id) != nil else { return }
                self.notify("settle", [id, success, json])
            }
        }
    }

    private func startHTTP(_ id: Int, payload: String) {
        do {
            guard let data = payload.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let address = object["url"] as? String, let url = URL(string: address), origin(url) == allowedOrigin,
                  url.user == nil, url.password == nil,
                  let method = object["method"] as? String, ["GET", "POST"].contains(method.uppercased()),
                  let headers = object["headers"] as? [String: String] else { throw PiRuntimeError.message("Invalid native HTTP request") }
            var request = URLRequest(url: url)
            request.httpMethod = method.uppercased()
            request.httpBody = (object["body"] as? String)?.data(using: .utf8)
            for (name, value) in headers {
                guard !name.contains(where: { $0.isNewline }), !value.contains(where: { $0.isNewline }) else {
                    throw PiRuntimeError.message("Invalid HTTP header")
                }
                request.setValue(value, forHTTPHeaderField: name)
            }
            let requestToSend = request
            requests[id] = Task { [weak self, session] in
                do {
                    let (bytes, response) = try await session.bytes(for: requestToSend)
                    guard let http = response as? HTTPURLResponse else { throw PiRuntimeError.message("Invalid HTTP response") }
                    let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                        result[String(describing: entry.key)] = String(describing: entry.value)
                    }
                    try await self?.deliverHTTP(id, kind: "headers", json: jsonString([
                        "status": http.statusCode, "headers": headers, "url": http.url?.absoluteString ?? address,
                    ]))
                    var chunk: [UInt8] = []
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if byte == 10 || chunk.count >= 16 * 1024 {
                            try await self?.deliverHTTP(id, kind: "chunk", json: jsonString(chunk), task: bytes.task)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { try await self?.deliverHTTP(id, kind: "chunk", json: jsonString(chunk), task: bytes.task) }
                    try await self?.deliverHTTP(id, kind: "end", json: "null")
                } catch {
                    try? await self?.deliverHTTP(id, kind: "error", json: (try? jsonString(error.localizedDescription)) ?? "\"Network error\"")
                }
                self?.queue.async { [weak self] in self?.requests.removeValue(forKey: id) }
            }
        } catch {
            notify("receiveHTTP", [id, "error", (try? jsonString(error.localizedDescription)) ?? "\"Invalid HTTP request\""])
        }
    }

    private func deliverHTTP(_ id: Int, kind: String, json: String, task: URLSessionDataTask? = nil) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                guard !closed, requests[id] != nil else { continuation.resume(throwing: CancellationError()); return }
                credits[id] = continuation
                do {
                    let canContinue = try invoke("receiveHTTP", [id, kind, json])?.toBool() ?? true
                    if canContinue { credits.removeValue(forKey: id)?.resume() }
                    else if credits[id] != nil, let task {
                        task.suspend()
                        suspended[id] = task
                    }
                } catch {
                    credits.removeValue(forKey: id)?.resume(throwing: error)
                    shutdown(error)
                }
            }
        }
    }

    private func cancelHTTP(_ id: Int) {
        requests.removeValue(forKey: id)?.cancel()
        suspended.removeValue(forKey: id)?.cancel()
        credits.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            // dispose() drains JS microtasks, which may call nativeFinish synchronously.
            // Detach first so closing, not that late callback, owns the run's terminal result.
            let continuation = currentRun?.continuation
            currentRun = nil
            notify("dispose", [])
            let error = PiRuntimeError.message("Runtime closed")
            shutdown(error)
            continuation?.resume(throwing: error)
        }
    }

    private func shutdown(_ error: any Error) {
        guard !closed else { return }
        closed = true
        for task in calls.values { task.cancel() }
        for task in requests.values { task.cancel() }
        for task in suspended.values { task.cancel() }
        for credit in credits.values { credit.resume(throwing: error) }
        for timer in timers.values { timer.cancel() }
        calls.removeAll(); requests.removeAll(); suspended.removeAll(); credits.removeAll(); timers.removeAll(); cancelledRuns.removeAll()
        currentRun?.continuation.resume(throwing: error)
        currentRun = nil
        session.invalidateAndCancel()
        runtime = nil
        context = nil
    }
}
