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
    private(set) var streamingMessageId: UUID?
    private(set) var streamingText = ""
    var onStreamingUpdate: ((UUID, String) -> Void)?
    var onStreamingStateChange: (() -> Void)?

    var isStreaming: Bool { task != nil }

    init(ledger: Ledger) throws {
        self.ledger = ledger
        self.conversation = try store.openConversation(ledgerId: ledger.id)
    }

    func send(_ text: String) throws {
        let (_, assistant) = try store.appendUserTurn(conversationId: conversation.id, text: text)
        run(assistantId: assistant.id)
    }

    func retry(_ assistant: Message) throws {
        try store.restartAssistantTurn(messageId: assistant.id)
        run(assistantId: assistant.id)
    }

    func stop() {
        task?.cancel()
    }

    func accept(_ proposal: Message) throws {
        try store.acceptProposal(messageId: proposal.id, ledgerId: ledger.id)
    }

    func dismiss(_ proposal: Message) {
        try? store.dismissProposal(messageId: proposal.id)
    }

    private static let proposeExpense = ToolSpec(
        name: "propose_expense",
        description: "向用户展示一张记账卡片，用户点「记账」后才会写入账本。每笔消费调用一次。",
        inputSchema: ExpenseProposal.inputSchema
    )

    private static func turn(_ message: Message) -> ChatTurn {
        guard message.kind == .proposal else {
            return ChatTurn(role: message.role == .user ? .user : .assistant, text: message.text)
        }
        let state = switch message.proposalState {
        case .accepted: "用户已确认，已记入账本"
        case .dismissed: "用户已取消，未记账"
        default: "等待用户确认"
        }
        return ChatTurn(role: .assistant, text: "（我提出了一张记账卡片：\(message.payload ?? "")；状态：\(state)）")
    }

    private func run(assistantId: UUID) {
        guard let provider = AgentSettings.load().makeProvider() else {
            try? store.updateAssistantTurn(messageId: assistantId, text: "", status: .failed, error: "未配置 AI 服务")
            return
        }
        let system: String
        let turns: [ChatTurn]
        do {
            system = try AgentContextBuilder.systemPrompt(store: store, ledger: ledger)
            turns = try store.writer.read { db in
                try Message.filter(Column("conversationId") == conversation.id.uuidString && Column("status") == "complete")
                    .order(Column("createdAt")).fetchAll(db)
            }.map(Self.turn)
        } catch {
            try? store.updateAssistantTurn(messageId: assistantId, text: "", status: .failed, error: error.localizedDescription)
            return
        }
        streamingMessageId = assistantId
        streamingText = ""
        task = Task { [store] in
            var text = ""
            var proposed = false
            var lastFlush = Date.distantPast
            do {
                for try await event in provider.stream(system: system, turns: turns, tools: [Self.proposeExpense]) {
                    switch event {
                    case .text(let delta):
                        text += delta
                        streamingText = text
                        onStreamingUpdate?(assistantId, text)
                        if Date().timeIntervalSince(lastFlush) > 0.3 {
                            try store.updateAssistantTurn(messageId: assistantId, text: text, status: .streaming)
                            lastFlush = Date()
                        }
                    case .toolCall(let call) where call.name == Self.proposeExpense.name:
                        try store.appendProposal(conversationId: conversation.id, payload: call.arguments)
                        proposed = true
                    case .toolCall:
                        continue
                    }
                }
                if proposed && text.isEmpty {
                    try store.discardEmptyTurn(messageId: assistantId)
                } else {
                    try store.updateAssistantTurn(messageId: assistantId, text: text, status: .complete)
                }
            } catch is CancellationError {
                try? store.updateAssistantTurn(messageId: assistantId, text: text, status: text.isEmpty ? .failed : .complete, error: text.isEmpty ? "已停止" : nil)
            } catch let AgentError.http(status, body) {
                try? store.updateAssistantTurn(messageId: assistantId, text: text, status: .failed, error: "HTTP \(status): \(body.prefix(300))")
            } catch {
                try? store.updateAssistantTurn(messageId: assistantId, text: text, status: .failed, error: error.localizedDescription)
            }
            task = nil
            streamingMessageId = nil
            onStreamingStateChange?()
        }
        onStreamingStateChange?()
    }
}
