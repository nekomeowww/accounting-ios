import AgentClient
import Foundation
import GRDB
import LedgerDomain
import LedgerPersistence

@MainActor
final class ChatSession {
    let ledger: Ledger
    let conversation: Conversation
    private let store = AppServices.store
    private var task: Task<Void, Never>?
    private var runtime: PiAgentRuntime?
    private var currentRunId: UUID?
    private var activeTextId: String?
    private var activeText = ""
    private var lastFlush = Date.distantPast
    private(set) var streamingMessageId: UUID?
    private(set) var streamingText = ""
    private(set) var toolStatus: String?
    var onStreamingUpdate: ((UUID, String) -> Void)?
    var onStreamingStateChange: (() -> Void)?
    var onRunError: ((String) -> Void)?

    var isStreaming: Bool { task != nil }

    init(ledger: Ledger) throws {
        self.ledger = ledger
        conversation = try store.openConversation(ledgerId: ledger.id)
    }

    func send(_ text: String) throws {
        guard task == nil else { throw AgentStoreError.busy }
        guard AgentSettings.load().isConfigured else { throw ChatSessionError.notConfigured }
        run(try store.beginAgentRun(conversationId: conversation.id, text: text))
    }

    func retry(_ assistant: Message) throws {
        guard task == nil else { throw AgentStoreError.busy }
        guard AgentSettings.load().isConfigured else { throw ChatSessionError.notConfigured }
        guard let runId = assistant.agentRunId else {
            let user = try store.writer.read { db in
                try Message.filter(Column("conversationId") == conversation.id.uuidString && Column("role") == "user" && Column("createdAt") < assistant.createdAt)
                    .order(Column("createdAt").desc).fetchOne(db)
            }
            guard let user else { throw AgentStoreError.cannotResume }
            try send(user.text)
            _ = try? store.writer.write { try assistant.delete($0) }
            return
        }
        if let prepared = try store.resumeAgentRun(runId: runId) { run(prepared) }
    }

    func stop() {
        task?.cancel()
        if let currentRunId { runtime?.abort(id: currentRunId.uuidString) }
    }

    func accept(_ proposal: Message, place: Candidate? = nil) throws {
        if proposal.kind == .repayment { return try store.acceptRepayment(messageId: proposal.id, ledgerId: ledger.id) }
        try store.acceptProposal(messageId: proposal.id, ledgerId: ledger.id, place: place)
    }

    func dismiss(_ proposal: Message) {
        try? store.dismissProposal(messageId: proposal.id)
    }

    private func run(_ prepared: PreparedAgentRun) {
        let runId = prepared.run.id
        currentRunId = runId
        task = Task { [store, conversation, ledger] in
            var status: AgentRunStatus = .failed
            var errorText: String?
            do {
                let settings = AgentSettings.load()
                let prompt = try AgentContextBuilder.systemPrompt(store: store, ledger: ledger)
                let cards = try store.agentProposalContext(conversationId: conversation.id)
                let system = cards.isEmpty ? prompt : prompt + "\n\n现有记账卡片状态：\n" + cards
                let config = try settings.configurationJSON(conversationId: conversation.id, systemPrompt: system, historyJSON: prepared.historyJSON)
                let runtime = try PiAgentRuntime(configurationJSON: config) { [weak self] operation, payload in
                    guard let self else { throw CancellationError() }
                    return try await self.handle(operation: operation, payload: payload, runId: runId)
                }
                self.runtime = runtime
                let result = try await runtime.run(id: runId.uuidString, inputJSON: prepared.inputJSON)
                let outcome = try Self.object(result)
                switch outcome["status"] as? String {
                case "complete": status = .complete
                case "aborted": status = .aborted
                case "failed": errorText = outcome["error"] as? String ?? "Agent 运行失败"
                default: throw ChatSessionError.invalidResponse
                }
            } catch is CancellationError {
                status = .aborted
            } catch {
                errorText = error.localizedDescription
            }
            runtime?.close()
            runtime = nil
            if let activeTextId, !activeText.isEmpty {
                try? store.updateAgentText(conversationId: conversation.id, runId: runId,
                                           messageId: activeTextId, text: activeText)
            }
            do {
                try store.finishAgentRun(conversationId: conversation.id, runId: runId, status: status, error: errorText)
            } catch {
                try? store.finishAgentRun(conversationId: conversation.id, runId: runId, status: .failed,
                                          error: error.localizedDescription)
                onRunError?("无法保存 Agent 运行结果：" + error.localizedDescription)
            }
            currentRunId = nil
            task = nil
            activeTextId = nil
            activeText = ""
            streamingMessageId = nil
            toolStatus = nil
            onStreamingStateChange?()
        }
        onStreamingStateChange?()
    }

    private func handle(operation: String, payload: String, runId: UUID) throws -> String {
        let value = try Self.object(payload)
        guard value["conversationId"] as? String == conversation.id.uuidString,
              value["runId"] as? String == runId.uuidString, currentRunId == runId else { throw AgentStoreError.staleRun }
        switch operation {
        case "checkpoint":
            guard let entry = value["entry"] as? [String: Any], let id = entry["id"] as? String,
                  let message = entry["message"] else { throw ChatSessionError.invalidResponse }
            try store.checkpointAgentMessage(conversationId: conversation.id, runId: runId, id: id, payload: try Self.json(message))
        case "tool":
            guard let name = value["name"] as? String, LedgerStore.cardTools.contains(name), let messageId = value["messageId"] as? String,
                  let callId = value["toolCallId"] as? String, let arguments = value["arguments"] else {
                throw ChatSessionError.invalidResponse
            }
            let execution = try store.executeAgentProposal(conversationId: conversation.id, runId: runId,
                                                           assistantMessageId: messageId, toolCallId: callId,
                                                           arguments: try Self.json(arguments))
            if execution.isError { throw ChatSessionError.tool(execution.errorMessage ?? "工具执行失败") }
            let result = try Self.object(execution.resultJSON)
            return try Self.json(["content": result["content"] ?? [], "details": result["details"] ?? [:]])
        case "event":
            try handleEvent(value, runId: runId)
        default: throw ChatSessionError.invalidResponse
        }
        return "null"
    }

    private func handleEvent(_ event: [String: Any], runId: UUID) throws {
        switch event["type"] as? String {
        case "text":
            guard let id = event["messageId"] as? String, let delta = event["delta"] as? String,
                  id.hasPrefix(runId.uuidString + ":") else { throw ChatSessionError.invalidResponse }
            if activeTextId != id {
                activeTextId = id
                activeText = ""
                lastFlush = .distantPast
            }
            activeText += delta
            if Date().timeIntervalSince(lastFlush) > 0.3 {
                try store.updateAgentText(conversationId: conversation.id, runId: runId, messageId: id, text: activeText)
                lastFlush = Date()
            }
            if let message = try store.writer.read({ db in
                try Message.filter(Column("conversationId") == conversation.id.uuidString && Column("agentMessageId") == id).fetchOne(db)
            }) {
                streamingMessageId = message.id
                streamingText = activeText
                onStreamingUpdate?(message.id, activeText)
            }
        case "message_end":
            if let id = streamingMessageId {
                streamingMessageId = nil
                onStreamingUpdate?(id, activeText)
            }
        case "tool_start":
            toolStatus = "正在生成记账卡片…"
            onStreamingStateChange?()
        case "tool_end":
            toolStatus = nil
            onStreamingStateChange?()
        case "message_start", "settled": break
        default: throw ChatSessionError.invalidResponse
        }
    }

    private static func object(_ json: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ChatSessionError.invalidResponse
        }
        return value
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }
}

private enum ChatSessionError: LocalizedError {
    case notConfigured, invalidResponse, tool(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: "未配置 AI 服务"
        case .invalidResponse: "Agent 响应格式无效"
        case .tool(let message): message
        }
    }
}
