import Foundation
import GRDB
import LedgerDomain

public struct SettlementRow: Hashable, Sendable {
    public var participantId: UUID
    public var participantName: String
    public var net: Money
}

public struct Settlement: Hashable, Sendable {
    public var currency: String
    public var rows: [SettlementRow]
    public var missingRates: [String]

    public init(currency: String, rows: [SettlementRow], missingRates: [String]) {
        self.currency = currency
        self.rows = rows
        self.missingRates = missingRates
    }
}

extension LedgerStore {
    public static func fetchRates(_ db: Database, ledgerId: UUID) throws -> [ExchangeRate] {
        try ExchangeRate.filter(Column("ledgerId") == ledgerId.uuidString).order(Column("currency")).fetchAll(db)
    }

    public static func fetchCurrenciesInUse(_ db: Database, ledgerId: UUID) throws -> [String] {
        try String.fetchAll(db, sql: """
                SELECT DISTINCT je.currency FROM journalEntry je
                JOIN journalTx t ON t.id = je.txId
                WHERE t.ledgerId = ?
                ORDER BY je.currency
                """, arguments: [ledgerId.uuidString])
    }

    public static func fetchSettlement(_ db: Database, ledgerId: UUID) throws -> Settlement {
        guard let ledger = try Ledger.fetchOne(db, key: ledgerId.uuidString) else {
            return Settlement(currency: "", rows: [], missingRates: [])
        }
        let target = ledger.settlementCurrency
        var rates = Dictionary(uniqueKeysWithValues: try fetchRates(db, ledgerId: ledgerId).map { ($0.currency, $0.rate) })
        rates[target] = 1
        var missing = Set<String>()
        var rows: [UUID: SettlementRow] = [:]
        for balance in try fetchBalances(db, ledgerId: ledgerId) {
            var row = rows[balance.participantId] ?? SettlementRow(participantId: balance.participantId, participantName: balance.participantName, net: Money(minor: 0, currency: target))
            if let rate = rates[balance.currency] {
                row.net.minor += balance.net.converted(to: target, rate: rate).minor
            } else if balance.netMinor != 0 {
                missing.insert(balance.currency)
            }
            rows[balance.participantId] = row
        }
        return Settlement(
            currency: target,
            rows: rows.values.sorted { $0.participantName < $1.participantName },
            missingRates: missing.sorted()
        )
    }

    public func observeSettlement(ledgerId: UUID) -> ValueObservation<ValueReducers.Fetch<Settlement>> {
        ValueObservation.tracking { try Self.fetchSettlement($0, ledgerId: ledgerId) }
    }

    public func setSettlementCurrency(ledgerId: UUID, currency: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE ledger SET settlementCurrency = ?, updatedAt = ?, updatedBy = ?, version = version + 1 WHERE id = ?",
                arguments: [currency, Date(), actorId.uuidString, ledgerId.uuidString]
            )
            try ExchangeRate.filter(Column("ledgerId") == ledgerId.uuidString).deleteAll(db)
        }
    }

    public func setRates(ledgerId: UUID, _ rates: [String: Decimal], source: RateSource, asOf: String? = nil) throws {
        let now = Date()
        try writer.write { db in
            for (currency, rate) in rates {
                try ExchangeRate(ledgerId: ledgerId, currency: currency, rate: rate, source: source, asOf: asOf, updatedAt: now).upsert(db)
            }
        }
    }
}
