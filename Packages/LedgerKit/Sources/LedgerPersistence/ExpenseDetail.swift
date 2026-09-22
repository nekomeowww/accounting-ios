import Foundation
import GRDB
import LedgerDomain

public struct ExpenseDetail: Hashable, Sendable {
    public struct Payment: Hashable, Sendable, Decodable, FetchableRecord {
        public var participantName: String
        public var amountMinor: Int64
        public var method: String?
    }

    public struct Share: Hashable, Sendable, Decodable, FetchableRecord {
        public var participantId: UUID
        public var participantName: String
        public var owedMinor: Int64
    }

    public var expense: Expense
    public var lines: [ExpenseLine]
    public var payments: [Payment]
    public var shares: [Share]
    public var settlementCurrency: String
    public var rate: Decimal?

    public var total: Money { Money(minor: lines.reduce(0) { $0 + $1.amountMinor }, currency: expense.currency) }

    public func money(_ minor: Int64) -> Money { Money(minor: minor, currency: expense.currency) }

    public func settled(_ minor: Int64) -> Money? {
        guard expense.currency != settlementCurrency, let rate else { return nil }
        return money(minor).converted(to: settlementCurrency, rate: rate)
    }
}

extension LedgerStore {
    public static func fetchExpenseDetail(_ db: Database, expenseId: UUID) throws -> ExpenseDetail? {
        let id = expenseId.uuidString
        guard let expense = try Expense.fetchOne(db, key: id), expense.deletedAt == nil,
              let ledger = try Ledger.fetchOne(db, key: expense.ledgerId.uuidString) else { return nil }
        let lines = try ExpenseLine.filter(Column("expenseId") == id).order(Column("sortOrder")).fetchAll(db)
        let payments = try ExpenseDetail.Payment.fetchAll(db, sql: """
                SELECT p.name AS participantName, ep.amountMinor, ep.method
                FROM expensePayment ep JOIN participant p ON p.id = ep.participantId
                WHERE ep.expenseId = ?
                ORDER BY ep.amountMinor DESC, p.name
                """, arguments: [id])
        let shares = try ExpenseDetail.Share.fetchAll(db, sql: """
                SELECT je.participantId, p.name AS participantName, -SUM(je.amountMinor) AS owedMinor
                FROM journalEntry je
                JOIN journalTx t ON t.id = je.txId
                JOIN participant p ON p.id = je.participantId
                WHERE t.sourceType = 'expense' AND t.sourceId = ? AND je.lineId IS NOT NULL
                GROUP BY je.participantId
                HAVING owedMinor != 0
                ORDER BY owedMinor DESC, p.name
                """, arguments: [id])
        let rate = try ExchangeRate
            .filter(Column("ledgerId") == ledger.id.uuidString && Column("currency") == expense.currency)
            .fetchOne(db)?.rate
        return ExpenseDetail(expense: expense, lines: lines, payments: payments, shares: shares, settlementCurrency: ledger.settlementCurrency, rate: rate)
    }

    public func observeExpenseDetail(expenseId: UUID) -> ValueObservation<ValueReducers.Fetch<ExpenseDetail?>> {
        ValueObservation.tracking { try Self.fetchExpenseDetail($0, expenseId: expenseId) }
    }
}
