import Foundation

public struct Ledger: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var type: String
    public var defaultCurrency: String
    public var settlementCurrency: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var version: Int64
    public var createdBy: UUID
    public var updatedBy: UUID

    public init(id: UUID, name: String, type: String, defaultCurrency: String, settlementCurrency: String, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil, version: Int64, createdBy: UUID, updatedBy: UUID) {
        self.id = id
        self.name = name
        self.type = type
        self.defaultCurrency = defaultCurrency
        self.settlementCurrency = settlementCurrency
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.version = version
        self.createdBy = createdBy
        self.updatedBy = updatedBy
    }
}

public enum RateSource: String, Sendable, Codable {
    case manual, fetched
}

public struct ExchangeRate: Hashable, Sendable, Codable {
    public var ledgerId: UUID
    public var currency: String
    public var rate: Decimal
    public var source: RateSource
    public var asOf: String?
    public var updatedAt: Date

    public init(ledgerId: UUID, currency: String, rate: Decimal, source: RateSource, asOf: String? = nil, updatedAt: Date) {
        self.ledgerId = ledgerId
        self.currency = currency
        self.rate = rate
        self.source = source
        self.asOf = asOf
        self.updatedAt = updatedAt
    }
}

public struct Participant: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var ledgerId: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var version: Int64
    public var createdBy: UUID
    public var updatedBy: UUID

    public init(id: UUID, ledgerId: UUID, name: String, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil, version: Int64, createdBy: UUID, updatedBy: UUID) {
        self.id = id
        self.ledgerId = ledgerId
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.version = version
        self.createdBy = createdBy
        self.updatedBy = updatedBy
    }
}

public enum MemberRole: String, Sendable, Codable {
    case owner, editor, viewer
}

public struct Member: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var ledgerId: UUID
    public var participantId: UUID
    public var actorId: UUID
    public var role: MemberRole
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var version: Int64
    public var createdBy: UUID
    public var updatedBy: UUID

    public init(id: UUID, ledgerId: UUID, participantId: UUID, actorId: UUID, role: MemberRole, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil, version: Int64, createdBy: UUID, updatedBy: UUID) {
        self.id = id
        self.ledgerId = ledgerId
        self.participantId = participantId
        self.actorId = actorId
        self.role = role
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.version = version
        self.createdBy = createdBy
        self.updatedBy = updatedBy
    }
}

public enum LocationSource: String, Sendable, Codable {
    case device, photo, manual
}

public struct Location: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double?
    public var source: LocationSource

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double? = nil, source: LocationSource) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.source = source
    }
}

public enum ExpenseSource: String, Sendable, Codable {
    case manual, agent
}

public struct Expense: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var ledgerId: UUID
    public var merchant: String
    public var note: String?
    public var category: String?
    public var occurredAt: Date
    public var timeZone: String
    public var currency: String
    public var latitude: Double?
    public var longitude: Double?
    public var horizontalAccuracy: Double?
    public var locationSource: LocationSource?
    public var source: ExpenseSource
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var version: Int64
    public var createdBy: UUID
    public var updatedBy: UUID

    public init(id: UUID, ledgerId: UUID, merchant: String, note: String? = nil, category: String? = nil, occurredAt: Date, timeZone: String, currency: String, location: Location? = nil, source: ExpenseSource, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil, version: Int64, createdBy: UUID, updatedBy: UUID) {
        self.id = id
        self.ledgerId = ledgerId
        self.merchant = merchant
        self.note = note
        self.category = category
        self.occurredAt = occurredAt
        self.timeZone = timeZone
        self.currency = currency
        self.latitude = location?.latitude
        self.longitude = location?.longitude
        self.horizontalAccuracy = location?.horizontalAccuracy
        self.locationSource = location?.source
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.version = version
        self.createdBy = createdBy
        self.updatedBy = updatedBy
    }
}

public enum LineKind: String, Sendable, Codable {
    case item, tax, service, tip, discount, rounding
}

public enum SplitRule: String, Sendable, Codable {
    case weighted, exact, proportional
}

public struct ExpenseLine: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var expenseId: UUID
    public var kind: LineKind
    public var name: String
    public var quantity: Int64
    public var unitMinor: Int64?
    public var amountMinor: Int64
    public var splitRule: SplitRule
    public var sortOrder: Int64

    public init(id: UUID, expenseId: UUID, kind: LineKind, name: String, quantity: Int64, unitMinor: Int64? = nil, amountMinor: Int64, splitRule: SplitRule, sortOrder: Int64) {
        self.id = id
        self.expenseId = expenseId
        self.kind = kind
        self.name = name
        self.quantity = quantity
        self.unitMinor = unitMinor
        self.amountMinor = amountMinor
        self.splitRule = splitRule
        self.sortOrder = sortOrder
    }
}

public struct LineConsumer: Hashable, Sendable, Codable {
    public var lineId: UUID
    public var participantId: UUID
    public var weight: Int64
    public var exactMinor: Int64?

    public init(lineId: UUID, participantId: UUID, weight: Int64 = 1, exactMinor: Int64? = nil) {
        self.lineId = lineId
        self.participantId = participantId
        self.weight = weight
        self.exactMinor = exactMinor
    }
}

public struct ExpensePayment: Hashable, Sendable, Codable {
    public var expenseId: UUID
    public var participantId: UUID
    public var amountMinor: Int64
    public var method: String?

    public init(expenseId: UUID, participantId: UUID, amountMinor: Int64, method: String? = nil) {
        self.expenseId = expenseId
        self.participantId = participantId
        self.amountMinor = amountMinor
        self.method = method
    }
}

public enum TransferKind: String, Sendable, Codable {
    case settlement, refund
}

public struct Transfer: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var ledgerId: UUID
    public var fromParticipantId: UUID
    public var toParticipantId: UUID
    public var currency: String
    public var amountMinor: Int64
    public var settlesCurrency: String
    public var settlesMinor: Int64
    public var method: String?
    public var externalRef: String?
    public var occurredAt: Date
    public var kind: TransferKind
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var version: Int64
    public var createdBy: UUID
    public var updatedBy: UUID

    public init(id: UUID, ledgerId: UUID, fromParticipantId: UUID, toParticipantId: UUID, currency: String, amountMinor: Int64, settlesCurrency: String, settlesMinor: Int64, method: String? = nil, externalRef: String? = nil, occurredAt: Date, kind: TransferKind, note: String? = nil, createdAt: Date, updatedAt: Date, deletedAt: Date? = nil, version: Int64, createdBy: UUID, updatedBy: UUID) {
        self.id = id
        self.ledgerId = ledgerId
        self.fromParticipantId = fromParticipantId
        self.toParticipantId = toParticipantId
        self.currency = currency
        self.amountMinor = amountMinor
        self.settlesCurrency = settlesCurrency
        self.settlesMinor = settlesMinor
        self.method = method
        self.externalRef = externalRef
        self.occurredAt = occurredAt
        self.kind = kind
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.version = version
        self.createdBy = createdBy
        self.updatedBy = updatedBy
    }
}

public enum JournalSourceType: String, Sendable, Codable {
    case expense, transfer
}

public struct JournalTx: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var ledgerId: UUID
    public var sourceType: JournalSourceType
    public var sourceId: UUID
    public var occurredAt: Date
    public var reversesTxId: UUID?

    public init(id: UUID, ledgerId: UUID, sourceType: JournalSourceType, sourceId: UUID, occurredAt: Date, reversesTxId: UUID? = nil) {
        self.id = id
        self.ledgerId = ledgerId
        self.sourceType = sourceType
        self.sourceId = sourceId
        self.occurredAt = occurredAt
        self.reversesTxId = reversesTxId
    }
}

public struct JournalEntry: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var txId: UUID
    public var participantId: UUID
    public var currency: String
    public var amountMinor: Int64
    public var lineId: UUID?

    public init(id: UUID, txId: UUID, participantId: UUID, currency: String, amountMinor: Int64, lineId: UUID? = nil) {
        self.id = id
        self.txId = txId
        self.participantId = participantId
        self.currency = currency
        self.amountMinor = amountMinor
        self.lineId = lineId
    }
}
