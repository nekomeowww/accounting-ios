import Foundation
import GRDB
import LedgerDomain

public struct Conversation: Hashable, Sendable, Codable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var ledgerId: UUID
    public var createdAt: Date
    public var updatedAt: Date

    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

public enum MessageRole: String, Sendable, Codable {
    case user, assistant
}

public enum MessageStatus: String, Sendable, Codable {
    case streaming, complete, failed
}

public enum MessageKind: String, Sendable, Codable {
    case text, proposal
}

public enum ProposalState: String, Sendable, Codable {
    case pending, accepted, dismissed
}

public struct Message: Hashable, Sendable, Codable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var conversationId: UUID
    public var role: MessageRole
    public var text: String
    public var status: MessageStatus
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var kind: MessageKind = .text
    public var payload: String?
    public var proposalState: ProposalState?
    public var expenseId: UUID?

    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

extension LedgerStore {
    public func openConversation(ledgerId: UUID) throws -> Conversation {
        try writer.write { db in
            if let existing = try Conversation.filter(Column("ledgerId") == ledgerId.uuidString).order(Column("createdAt").desc).fetchOne(db) {
                return existing
            }
            let now = Date()
            let conversation = Conversation(id: UUID(), ledgerId: ledgerId, createdAt: now, updatedAt: now)
            try conversation.insert(db)
            return conversation
        }
    }

    public func appendUserTurn(conversationId: UUID, text: String) throws -> (user: Message, assistant: Message) {
        let now = Date()
        let user = Message(id: UUID(), conversationId: conversationId, role: .user, text: text, status: .complete, createdAt: now, updatedAt: now)
        let assistant = Message(id: UUID(), conversationId: conversationId, role: .assistant, text: "", status: .streaming, createdAt: now.addingTimeInterval(0.001), updatedAt: now)
        try writer.write { db in
            try user.insert(db)
            try assistant.insert(db)
            try db.execute(sql: "UPDATE conversation SET updatedAt = ? WHERE id = ?", arguments: [now, conversationId.uuidString])
        }
        return (user, assistant)
    }

    public func restartAssistantTurn(messageId: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE message SET text = '', status = 'streaming', error = NULL, updatedAt = ? WHERE id = ?", arguments: [Date(), messageId.uuidString])
        }
    }

    public func updateAssistantTurn(messageId: UUID, text: String, status: MessageStatus, error: String? = nil) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE message SET text = ?, status = ?, error = ?, updatedAt = ? WHERE id = ?", arguments: [text, status.rawValue, error, Date(), messageId.uuidString])
        }
    }

    public func appendProposal(conversationId: UUID, payload: String) throws {
        let now = Date()
        let proposal = Message(
            id: UUID(), conversationId: conversationId, role: .assistant, text: "", status: .complete,
            createdAt: now, updatedAt: now, kind: .proposal, payload: payload, proposalState: .pending
        )
        try writer.write { try proposal.insert($0) }
    }

    public func discardEmptyTurn(messageId: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id = ? AND kind = 'text' AND text = ''", arguments: [messageId.uuidString])
        }
    }

    @discardableResult
    public func acceptProposal(messageId: UUID, ledgerId: UUID, timeZone: TimeZone = .current) throws -> Expense {
        try writer.write { db in
            guard let message = try Message.fetchOne(db, key: messageId.uuidString), message.kind == .proposal,
                  message.proposalState == .pending, let payload = message.payload else { throw ProposalError.notPending }
            let participants = try Participant
                .filter(Column("ledgerId") == ledgerId.uuidString && Column("deletedAt") == nil)
                .order(Column("createdAt"))
                .fetchAll(db)
                .map { (id: $0.id, name: $0.name) }
            let draft = try ExpenseProposal.decode(payload).draft(ledgerId: ledgerId, participants: participants, timeZone: timeZone)
            let expense = try Self.insertExpense(db, draft, actorId: actorId)
            try db.execute(
                sql: "UPDATE message SET proposalState = 'accepted', expenseId = ?, updatedAt = ? WHERE id = ?",
                arguments: [expense.id.uuidString, Date(), messageId.uuidString]
            )
            return expense
        }
    }

    public func dismissProposal(messageId: UUID) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE message SET proposalState = 'dismissed', updatedAt = ? WHERE id = ? AND proposalState = 'pending'",
                arguments: [Date(), messageId.uuidString]
            )
        }
    }

    public func observeMessages(conversationId: UUID) -> ValueObservation<ValueReducers.Fetch<[Message]>> {
        ValueObservation.tracking { db in
            try Message.filter(Column("conversationId") == conversationId.uuidString).order(Column("createdAt")).fetchAll(db)
        }
    }

    static func failInterruptedStreams(_ db: Database) throws {
        try db.execute(sql: "UPDATE message SET status = 'failed', error = 'interrupted', updatedAt = ? WHERE status = 'streaming'", arguments: [Date()])
    }
}
