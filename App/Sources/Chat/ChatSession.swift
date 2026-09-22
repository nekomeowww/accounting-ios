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
            }.map { ChatTurn(role: $0.role == .user ? .user : .assistant, text: $0.text) }
        } catch {
            try? store.updateAssistantTurn(messageId: assistantId, text: "", status: .failed, error: error.localizedDescription)
            return
        }
        streamingMessageId = assistantId
        streamingText = ""
        task = Task { [store] in
            var text = ""
            var lastFlush = Date.distantPast
            do {
                for try await delta in provider.stream(system: system, turns: turns) {
                    text += delta
                    streamingText = text
                    onStreamingUpdate?(assistantId, text)
                    if Date().timeIntervalSince(lastFlush) > 0.3 {
                        try store.updateAssistantTurn(messageId: assistantId, text: text, status: .streaming)
                        lastFlush = Date()
                    }
                }
                try store.updateAssistantTurn(messageId: assistantId, text: text, status: .complete)
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
