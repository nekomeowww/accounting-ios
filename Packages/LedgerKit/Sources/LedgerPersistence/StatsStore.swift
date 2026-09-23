import Foundation
import GRDB
import LedgerDomain

public struct LedgerStats: Hashable, Sendable {
    public struct Person: Hashable, Sendable {
        public var participantId: UUID
        public var name: String
        public var shared: Money
        public var personal: Money
        public var total: Money { Money(minor: shared.minor + personal.minor, currency: shared.currency) }
    }

    public struct Category: Hashable, Sendable {
        public var name: String
        public var shared: Money
        public var personal: Money
        public var total: Money { Money(minor: shared.minor + personal.minor, currency: shared.currency) }
    }

    public var currency: String
    public var people: [Person]
    public var categories: [Category]
    public var missingRates: [String]
}

extension LedgerStore {
    private struct OwedRow: Decodable, FetchableRecord {
        var participantId: UUID
        var name: String
        var currency: String
        var sharedMinor: Int64
        var personalMinor: Int64
    }

    private struct CategoryRow: Decodable, FetchableRecord {
        var category: String?
        var currency: String
        var sharedMinor: Int64
        var personalMinor: Int64
    }

    private static let consumerCountSQL = """
            (SELECT COUNT(DISTINCT lc.participantId) FROM lineConsumer lc JOIN expenseLine l ON l.id = lc.lineId
             WHERE l.expenseId = e.id AND (lc.weight > 0 OR lc.exactMinor > 0))
            """

    public static func fetchStats(_ db: Database, ledgerId: UUID) throws -> LedgerStats {
        guard let ledger = try Ledger.fetchOne(db, key: ledgerId.uuidString) else {
            return LedgerStats(currency: "", people: [], categories: [], missingRates: [])
        }
        let target = ledger.settlementCurrency
        var rates = Dictionary(uniqueKeysWithValues: try fetchRates(db, ledgerId: ledgerId).map { ($0.currency, $0.rate) })
        rates[target] = 1
        var missing = Set<String>()
        func convert(_ minor: Int64, _ currency: String) -> Int64 {
            guard let rate = rates[currency] else {
                if minor != 0 { missing.insert(currency) }
                return 0
            }
            return Money(minor: minor, currency: currency).converted(to: target, rate: rate).minor
        }

        let owed = try OwedRow.fetchAll(db, sql: """
                SELECT je.participantId, p.name, je.currency,
                  SUM(CASE WHEN \(consumerCountSQL) > 1 THEN -je.amountMinor ELSE 0 END) AS sharedMinor,
                  SUM(CASE WHEN \(consumerCountSQL) > 1 THEN 0 ELSE -je.amountMinor END) AS personalMinor
                FROM journalEntry je
                JOIN journalTx t ON t.id = je.txId AND t.sourceType = 'expense'
                JOIN expense e ON e.id = t.sourceId AND e.deletedAt IS NULL
                JOIN participant p ON p.id = je.participantId
                WHERE t.ledgerId = ? AND je.lineId IS NOT NULL
                GROUP BY je.participantId, je.currency
                """, arguments: [ledgerId.uuidString])
        var people: [UUID: LedgerStats.Person] = [:]
        for row in owed {
            var person = people[row.participantId] ?? .init(participantId: row.participantId, name: row.name,
                                                            shared: Money(minor: 0, currency: target), personal: Money(minor: 0, currency: target))
            person.shared.minor += convert(row.sharedMinor, row.currency)
            person.personal.minor += convert(row.personalMinor, row.currency)
            people[row.participantId] = person
        }

        let byCategory = try CategoryRow.fetchAll(db, sql: """
                SELECT e.category, e.currency,
                  SUM(CASE WHEN \(consumerCountSQL) > 1 THEN l.amountMinor ELSE 0 END) AS sharedMinor,
                  SUM(CASE WHEN \(consumerCountSQL) > 1 THEN 0 ELSE l.amountMinor END) AS personalMinor
                FROM expense e JOIN expenseLine l ON l.expenseId = e.id
                WHERE e.ledgerId = ? AND e.deletedAt IS NULL
                GROUP BY e.category, e.currency
                """, arguments: [ledgerId.uuidString])
        var categories: [String: LedgerStats.Category] = [:]
        for row in byCategory {
            let name = row.category?.isEmpty == false ? row.category! : "其他"
            var category = categories[name] ?? .init(name: name, shared: Money(minor: 0, currency: target), personal: Money(minor: 0, currency: target))
            category.shared.minor += convert(row.sharedMinor, row.currency)
            category.personal.minor += convert(row.personalMinor, row.currency)
            categories[name] = category
        }

        return LedgerStats(
            currency: target,
            people: people.values.sorted { $0.name < $1.name },
            categories: categories.values.sorted { $0.total.minor > $1.total.minor },
            missingRates: missing.sorted()
        )
    }

    public func observeStats(ledgerId: UUID) -> ValueObservation<ValueReducers.Fetch<LedgerStats>> {
        ValueObservation.tracking { try Self.fetchStats($0, ledgerId: ledgerId) }
    }
}
