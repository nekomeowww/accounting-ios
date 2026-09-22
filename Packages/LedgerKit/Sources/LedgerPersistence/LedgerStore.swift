import Foundation
import GRDB
import LedgerDomain

public final class LedgerStore: Sendable {
    public let writer: any DatabaseWriter
    public let actorId: UUID

    public init(writer: any DatabaseWriter, actorId: UUID) throws {
        self.writer = writer
        self.actorId = actorId
        try Migrations.migrator.migrate(writer)
    }

    public static func onDisk(at url: URL, actorId: UUID) throws -> LedgerStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try LedgerStore(writer: try DatabasePool(path: url.path, configuration: config), actorId: actorId)
    }

    public static func inMemory(actorId: UUID = UUID()) throws -> LedgerStore {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try LedgerStore(writer: try DatabaseQueue(configuration: config), actorId: actorId)
    }

    @discardableResult
    public func createLedger(name: String, type: String = "trip", currency: String, myName: String) throws -> (ledger: Ledger, me: Participant) {
        let now = Date()
        let ledger = Ledger(id: UUID(), name: name, type: type, defaultCurrency: currency, createdAt: now, updatedAt: now, version: 1, createdBy: actorId, updatedBy: actorId)
        let me = Participant(id: UUID(), ledgerId: ledger.id, name: myName, createdAt: now, updatedAt: now, version: 1, createdBy: actorId, updatedBy: actorId)
        let member = Member(id: UUID(), ledgerId: ledger.id, participantId: me.id, actorId: actorId, role: .owner, createdAt: now, updatedAt: now, version: 1, createdBy: actorId, updatedBy: actorId)
        try writer.write { db in
            try ledger.insert(db)
            try me.insert(db)
            try member.insert(db)
        }
        return (ledger, me)
    }

    @discardableResult
    public func addParticipant(ledgerId: UUID, name: String) throws -> Participant {
        let now = Date()
        let participant = Participant(id: UUID(), ledgerId: ledgerId, name: name, createdAt: now, updatedAt: now, version: 1, createdBy: actorId, updatedBy: actorId)
        try writer.write { try participant.insert($0) }
        return participant
    }

    @discardableResult
    public func createExpense(_ draft: ExpenseDraft) throws -> Expense {
        try writer.write { db in
            let participantIds = try Participant
                .filter(Column("ledgerId") == draft.ledgerId.uuidString && Column("deletedAt") == nil)
                .fetchAll(db)
                .map(\.id)
            let aggregate = try ExpenseBuilder.build(draft, ledgerParticipantIds: Set(participantIds), actorId: actorId)
            try aggregate.expense.insert(db)
            for line in aggregate.lines { try line.insert(db) }
            for consumer in aggregate.consumers { try consumer.insert(db) }
            for payment in aggregate.payments { try payment.insert(db) }
            try aggregate.journalTx.insert(db)
            for entry in aggregate.entries { try entry.insert(db) }
            return aggregate.expense
        }
    }
}
