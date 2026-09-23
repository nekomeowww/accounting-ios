import Foundation
import GRDB
import LedgerDomain

public struct ActivityRow: Hashable, Sendable, Decodable, FetchableRecord, Identifiable {
    public var id: UUID
    public var merchant: String
    public var occurredAt: Date
    public var timeZone: String
    public var currency: String
    public var totalMinor: Int64
    public var payerNames: String
    public var consumerCount: Int
    public var placeName: String?
    public var placeBranch: String?
    public var placeAddress: String?

    public var total: Money { Money(minor: totalMinor, currency: currency) }
}

public struct BalanceRow: Hashable, Sendable, Decodable, FetchableRecord {
    public var participantId: UUID
    public var participantName: String
    public var currency: String
    public var netMinor: Int64

    public var net: Money { Money(minor: netMinor, currency: currency) }
}

extension LedgerStore {
    static let payerAndConsumerColumnsSQL = """
            (SELECT COALESCE(group_concat(pp.name, ', '), '') FROM expensePayment ep
               JOIN participant pp ON pp.id = ep.participantId WHERE ep.expenseId = e.id) AS payerNames,
            (SELECT COALESCE(group_concat(ep.participantId, ','), '') FROM expensePayment ep
               WHERE ep.expenseId = e.id) AS payerParticipantIds,
            (SELECT COUNT(DISTINCT lc.participantId) FROM lineConsumer lc
               JOIN expenseLine l ON l.id = lc.lineId
               WHERE l.expenseId = e.id AND (lc.weight > 0 OR lc.exactMinor > 0)) AS consumerCount
            """

    public func observeLedgers() -> ValueObservation<ValueReducers.Fetch<[Ledger]>> {
        ValueObservation.tracking { db in
            try Ledger.filter(Column("deletedAt") == nil).order(Column("createdAt").desc).fetchAll(db)
        }
    }

    public func observeActivity(ledgerId: UUID) -> ValueObservation<ValueReducers.Fetch<[ActivityRow]>> {
        ValueObservation.tracking { try Self.fetchActivity($0, ledgerId: ledgerId) }
    }

    public static func fetchActivity(_ db: Database, ledgerId: UUID) throws -> [ActivityRow] {
        try ActivityRow.fetchAll(db, sql: """
                SELECT e.id, e.merchant, e.occurredAt, e.timeZone, e.currency,
                  (SELECT COALESCE(SUM(amountMinor), 0) FROM expenseLine WHERE expenseId = e.id) AS totalMinor,
                  \(payerAndConsumerColumnsSQL),
                  p.name AS placeName, p.branch AS placeBranch, p.address AS placeAddress
                FROM expense e
                LEFT JOIN place p ON p.id = e.placeId
                WHERE e.ledgerId = ? AND e.deletedAt IS NULL
                ORDER BY e.occurredAt DESC
                """, arguments: [ledgerId.uuidString])
    }

    public func observeBalances(ledgerId: UUID) -> ValueObservation<ValueReducers.Fetch<[BalanceRow]>> {
        ValueObservation.tracking { try Self.fetchBalances($0, ledgerId: ledgerId) }
    }

    public static func fetchBalances(_ db: Database, ledgerId: UUID) throws -> [BalanceRow] {
        try BalanceRow.fetchAll(db, sql: """
                SELECT je.participantId, p.name AS participantName, je.currency, SUM(je.amountMinor) AS netMinor
                FROM journalEntry je
                JOIN journalTx t ON t.id = je.txId
                JOIN participant p ON p.id = je.participantId
                WHERE t.ledgerId = ?
                GROUP BY je.participantId, je.currency
                ORDER BY p.name
                """, arguments: [ledgerId.uuidString])
    }

    public func participants(ledgerId: UUID) throws -> [Participant] {
        try writer.read { db in
            try Participant.filter(Column("ledgerId") == ledgerId.uuidString && Column("deletedAt") == nil).order(Column("createdAt")).fetchAll(db)
        }
    }
}
