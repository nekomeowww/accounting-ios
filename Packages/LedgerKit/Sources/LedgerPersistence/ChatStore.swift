import Foundation
import GRDB

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

public struct Message: Hashable, Sendable, Codable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var conversationId: UUID
    public var role: MessageRole
    public var text: String
    public var status: MessageStatus
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date

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

    public func observeMessages(conversationId: UUID) -> ValueObservation<ValueReducers.Fetch<[Message]>> {
        ValueObservation.tracking { db in
            try Message.filter(Column("conversationId") == conversationId.uuidString).order(Column("createdAt")).fetchAll(db)
        }
    }

    static func failInterruptedStreams(_ db: Database) throws {
        try db.execute(sql: "UPDATE message SET status = 'failed', error = 'interrupted', updatedAt = ? WHERE status = 'streaming'", arguments: [Date()])
    }
}
