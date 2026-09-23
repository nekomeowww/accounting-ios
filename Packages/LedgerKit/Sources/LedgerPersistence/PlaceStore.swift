import Foundation
import GRDB
import LedgerDomain

public struct MapPin: Hashable, Sendable, Identifiable {
    public struct ExpenseRef: Hashable, Sendable {
        public var expenseId: UUID
        public var merchant: String
        public var occurredAt: Date
        public var timeZone: String
        public var currency: String
        public var totalMinor: Int64
        public var payerNames: String
        public var consumerCount: Int
    }

    public var place: Place
    public var expenseCount: Int
    public var expenses: [ExpenseRef]
    public var dominantCategory: String?
    public var total: Money?

    public var id: UUID { place.id }
}

public struct LodgingPlace: Hashable, Sendable {
    public var place: Place
    public var startAt: Date
    public var endAt: Date
}

extension LedgerStore {
    @discardableResult
    public static func upsertPlace(_ db: Database, ledgerId: UUID, candidate: Candidate) throws -> Place {
        let now = Date()
        if let providerId = candidate.providerId,
           var existing = try Place
            .filter(Column("ledgerId") == ledgerId.uuidString && Column("provider") == "apple" && Column("providerId") == providerId)
            .fetchOne(db) {
            existing.name = candidate.name
            existing.address = candidate.address
            existing.phone = candidate.phone
            existing.category = candidate.category
            existing.latitude = candidate.latitude
            existing.longitude = candidate.longitude
            existing.updatedAt = now
            try existing.update(db)
            return existing
        }
        let place = Place(
            id: UUID(), ledgerId: ledgerId, name: candidate.name, address: candidate.address, phone: candidate.phone,
            category: candidate.category, latitude: candidate.latitude, longitude: candidate.longitude,
            provider: "apple", providerId: candidate.providerId, createdAt: now, updatedAt: now
        )
        try place.insert(db)
        return place
    }

    public func setExpensePlace(expenseId: UUID, candidate: Candidate?) throws {
        try writer.write { db in
            guard let expense = try Expense.fetchOne(db, key: expenseId.uuidString) else { return }
            if let candidate {
                let place = try Self.upsertPlace(db, ledgerId: expense.ledgerId, candidate: candidate)
                try db.execute(
                    sql: "UPDATE expense SET placeId = ?, placeQuery = NULL, updatedAt = ? WHERE id = ?",
                    arguments: [place.id.uuidString, Date(), expenseId.uuidString]
                )
            } else {
                try db.execute(
                    sql: "UPDATE expense SET placeId = NULL, updatedAt = ? WHERE id = ?",
                    arguments: [Date(), expenseId.uuidString]
                )
            }
        }
    }

    public static func fetchPlaces(_ db: Database, ledgerId: UUID) throws -> [Place] {
        try Place.filter(Column("ledgerId") == ledgerId.uuidString).order(Column("name")).fetchAll(db)
    }

    public static func fetchLodgingPlaces(_ db: Database, ledgerId: UUID) throws -> [LodgingPlace] {
        struct Row: Decodable, FetchableRecord {
            var placeId: UUID
            var name: String
            var branch: String?
            var address: String?
            var phone: String?
            var category: String?
            var latitude: Double
            var longitude: Double
            var provider: String
            var providerId: String?
            var createdAt: Date
            var updatedAt: Date
            var startAt: Date
            var endAt: Date
        }
        let rows = try Row.fetchAll(db, sql: """
                SELECT p.id AS placeId, p.name, p.branch, p.address, p.phone, p.category, p.latitude, p.longitude,
                  p.provider, p.providerId, p.createdAt, p.updatedAt,
                  MIN(e.occurredAt) AS startAt, MAX(e.occurredAt) AS endAt
                FROM place p
                JOIN expense e ON e.placeId = p.id AND e.deletedAt IS NULL
                WHERE p.ledgerId = ? AND e.category = '住宿'
                GROUP BY p.id
                ORDER BY startAt
                """, arguments: [ledgerId.uuidString])
        return rows.map {
            LodgingPlace(
                place: Place(
                    id: $0.placeId, ledgerId: ledgerId, name: $0.name, branch: $0.branch, address: $0.address, phone: $0.phone,
                    category: $0.category, latitude: $0.latitude, longitude: $0.longitude, provider: $0.provider,
                    providerId: $0.providerId, createdAt: $0.createdAt, updatedAt: $0.updatedAt
                ),
                startAt: $0.startAt, endAt: $0.endAt
            )
        }
    }

    public static func fetchMapPins(_ db: Database, ledgerId: UUID) throws -> [MapPin] {
        struct Row: Decodable, FetchableRecord {
            var placeId: UUID
            var name: String
            var branch: String?
            var address: String?
            var phone: String?
            var placeCategory: String?
            var latitude: Double
            var longitude: Double
            var provider: String
            var providerId: String?
            var createdAt: Date
            var updatedAt: Date
            var expenseId: UUID
            var merchant: String
            var occurredAt: Date
            var timeZone: String
            var currency: String
            var expenseCategory: String?
            var totalMinor: Int64
            var payerNames: String
            var consumerCount: Int
        }
        let rows = try Row.fetchAll(db, sql: """
                SELECT p.id AS placeId, p.name, p.branch, p.address, p.phone, p.category AS placeCategory,
                  p.latitude, p.longitude, p.provider, p.providerId, p.createdAt, p.updatedAt,
                  e.id AS expenseId, e.merchant, e.occurredAt, e.timeZone, e.currency, e.category AS expenseCategory,
                  (SELECT COALESCE(SUM(amountMinor), 0) FROM expenseLine WHERE expenseId = e.id) AS totalMinor,
                  (SELECT COALESCE(group_concat(pt.name, ', '), '') FROM expensePayment ep
                     JOIN participant pt ON pt.id = ep.participantId WHERE ep.expenseId = e.id) AS payerNames,
                  (SELECT COUNT(DISTINCT lc.participantId) FROM lineConsumer lc
                     JOIN expenseLine l ON l.id = lc.lineId
                     WHERE l.expenseId = e.id AND (lc.weight > 0 OR lc.exactMinor > 0)) AS consumerCount
                FROM place p
                JOIN expense e ON e.placeId = p.id AND e.deletedAt IS NULL
                WHERE p.ledgerId = ?
                ORDER BY p.name, e.occurredAt
                """, arguments: [ledgerId.uuidString])
        guard !rows.isEmpty else { return [] }

        let settlementCurrency = try Ledger.fetchOne(db, key: ledgerId.uuidString)?.settlementCurrency
        let rates = Dictionary(uniqueKeysWithValues: try fetchRates(db, ledgerId: ledgerId).map { ($0.currency, $0.rate) })

        var order: [UUID] = []
        var places: [UUID: Place] = [:]
        var expensesByPlace: [UUID: [MapPin.ExpenseRef]] = [:]
        var categoryCounts: [UUID: [String: Int]] = [:]

        for row in rows {
            if places[row.placeId] == nil {
                order.append(row.placeId)
                places[row.placeId] = Place(
                    id: row.placeId, ledgerId: ledgerId, name: row.name, branch: row.branch, address: row.address,
                    phone: row.phone, category: row.placeCategory, latitude: row.latitude, longitude: row.longitude,
                    provider: row.provider, providerId: row.providerId, createdAt: row.createdAt, updatedAt: row.updatedAt
                )
            }
            expensesByPlace[row.placeId, default: []].append(MapPin.ExpenseRef(
                expenseId: row.expenseId, merchant: row.merchant, occurredAt: row.occurredAt,
                timeZone: row.timeZone, currency: row.currency, totalMinor: row.totalMinor,
                payerNames: row.payerNames, consumerCount: row.consumerCount
            ))
            if let category = row.expenseCategory {
                categoryCounts[row.placeId, default: [:]][category, default: 0] += 1
            }
        }

        return order.map { id in
            let expenses = expensesByPlace[id] ?? []
            let dominantCategory = categoryCounts[id]?.max { $0.value < $1.value }?.key
            var total: Money?
            if let settlementCurrency {
                var totalMinor: Int64 = 0
                var allRated = true
                for expense in expenses {
                    if expense.currency == settlementCurrency {
                        totalMinor += expense.totalMinor
                    } else if let rate = rates[expense.currency] {
                        totalMinor += Money(minor: expense.totalMinor, currency: expense.currency).converted(to: settlementCurrency, rate: rate).minor
                    } else {
                        allRated = false
                        break
                    }
                }
                if allRated { total = Money(minor: totalMinor, currency: settlementCurrency) }
            }
            return MapPin(place: places[id]!, expenseCount: expenses.count, expenses: expenses, dominantCategory: dominantCategory, total: total)
        }
    }

    public func observeMapPins(ledgerId: UUID) -> ValueObservation<ValueReducers.Fetch<[MapPin]>> {
        ValueObservation.tracking { try Self.fetchMapPins($0, ledgerId: ledgerId) }
    }
}
