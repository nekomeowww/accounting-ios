import Foundation
import GRDB
import LedgerDomain

public enum ExpenseStoreError: Error, Equatable, Sendable, LocalizedError {
    case notFound, versionConflict

    public var errorDescription: String? {
        switch self {
        case .notFound: "这笔消费不存在或已删除"
        case .versionConflict: "这笔消费已在别处修改，请重新打开后再改"
        }
    }
}

public struct EditableExpense: Hashable, Sendable {
    public var draft: ExpenseDraft
    public var version: Int64
}

extension LedgerStore {
    public func editableExpense(id: UUID) throws -> EditableExpense {
        try writer.read { db in
            guard let expense = try Expense.fetchOne(db, key: id.uuidString), expense.deletedAt == nil else { throw ExpenseStoreError.notFound }
            return EditableExpense(draft: try Self.storedDraft(db, expense), version: expense.version)
        }
    }

    @discardableResult
    public func updateExpense(id: UUID, _ draft: ExpenseDraft, expectedVersion: Int64) throws -> Int64 {
        try writer.write { db in
            guard var expense = try Expense.fetchOne(db, key: id.uuidString), expense.deletedAt == nil else { throw ExpenseStoreError.notFound }
            guard expense.version == expectedVersion else { throw ExpenseStoreError.versionConflict }
            expense.merchant = draft.merchant
            expense.note = draft.note
            expense.category = draft.category
            expense.occurredAt = draft.occurredAt
            expense.endsAt = draft.endsAt
            expense.timeZone = draft.timeZone
            expense.currency = draft.currency
            expense.originalCurrency = draft.original?.currency
            expense.originalMinor = draft.original?.minor
            try Self.replaceContents(db, &expense, draft, actorId: actorId)
            return expense.version
        }
    }

    public func deleteExpense(id: UUID) throws {
        try writer.write { db in
            guard var expense = try Expense.fetchOne(db, key: id.uuidString), expense.deletedAt == nil else { throw ExpenseStoreError.notFound }
            expense.deletedAt = Date()
            expense.updatedAt = Date()
            expense.updatedBy = actorId
            expense.version += 1
            try expense.update(db)
            try db.execute(sql: "DELETE FROM journalTx WHERE sourceType = 'expense' AND sourceId = ?", arguments: [id.uuidString])
        }
    }

    public func restoreExpense(id: UUID) throws {
        try writer.write { db in
            guard var expense = try Expense.fetchOne(db, key: id.uuidString), expense.deletedAt != nil else { throw ExpenseStoreError.notFound }
            let draft = try Self.storedDraft(db, expense)
            expense.deletedAt = nil
            try Self.replaceContents(db, &expense, draft, actorId: actorId)
        }
    }

    static func storedDraft(_ db: Database, _ expense: Expense) throws -> ExpenseDraft {
        let lines = try ExpenseLine.filter(Column("expenseId") == expense.id.uuidString).order(Column("sortOrder")).fetchAll(db)
        let consumers = try LineConsumer.filter(lines.map(\.id.uuidString).contains(Column("lineId"))).fetchAll(db)
        let payments = try ExpensePayment.filter(Column("expenseId") == expense.id.uuidString).fetchAll(db)
        let location = expense.latitude.flatMap { latitude in
            expense.longitude.map { Location(latitude: latitude, longitude: $0, horizontalAccuracy: expense.horizontalAccuracy, source: expense.locationSource ?? .manual) }
        }
        return ExpenseDraft(
            ledgerId: expense.ledgerId, merchant: expense.merchant, note: expense.note, category: expense.category,
            occurredAt: expense.occurredAt, endsAt: expense.endsAt, timeZone: expense.timeZone, currency: expense.currency,
            original: expense.original, location: location, source: expense.source,
            lines: lines.map { line in
                LineDraft(kind: line.kind, name: line.name, quantity: line.quantity, unitMinor: line.unitMinor, amountMinor: line.amountMinor,
                          splitRule: line.splitRule,
                          consumers: consumers.filter { $0.lineId == line.id }.map { ConsumerDraft($0.participantId, weight: $0.weight, exactMinor: $0.exactMinor) })
            },
            payments: payments.map { PaymentDraft($0.participantId, amountMinor: $0.amountMinor, method: $0.method) }
        )
    }

    private static func replaceContents(_ db: Database, _ expense: inout Expense, _ draft: ExpenseDraft, actorId: UUID) throws {
        let participantIds = try Participant
            .filter(Column("ledgerId") == expense.ledgerId.uuidString && Column("deletedAt") == nil)
            .fetchAll(db).map(\.id)
        let aggregate = try ExpenseBuilder.build(draft, ledgerParticipantIds: Set(participantIds), actorId: actorId, expenseId: expense.id)
        try db.execute(sql: "DELETE FROM journalTx WHERE sourceType = 'expense' AND sourceId = ?", arguments: [expense.id.uuidString])
        try ExpensePayment.filter(Column("expenseId") == expense.id.uuidString).deleteAll(db)
        try ExpenseLine.filter(Column("expenseId") == expense.id.uuidString).deleteAll(db)
        expense.updatedAt = Date()
        expense.updatedBy = actorId
        expense.version += 1
        try expense.update(db)
        for line in aggregate.lines { try line.insert(db) }
        for consumer in aggregate.consumers { try consumer.insert(db) }
        for payment in aggregate.payments { try payment.insert(db) }
        try aggregate.journalTx.insert(db)
        for entry in aggregate.entries { try entry.insert(db) }
    }
}
