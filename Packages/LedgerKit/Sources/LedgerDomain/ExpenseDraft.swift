import Foundation

public struct LineDraft: Hashable, Sendable {
    public var kind: LineKind
    public var name: String
    public var quantity: Int64
    public var unitMinor: Int64?
    public var amountMinor: Int64
    public var splitRule: SplitRule
    public var consumers: [ConsumerDraft]

    public init(kind: LineKind = .item, name: String, quantity: Int64 = 1, unitMinor: Int64? = nil, amountMinor: Int64, splitRule: SplitRule = .weighted, consumers: [ConsumerDraft] = []) {
        self.kind = kind
        self.name = name
        self.quantity = quantity
        self.unitMinor = unitMinor
        self.amountMinor = amountMinor
        self.splitRule = splitRule
        self.consumers = consumers
    }
}

public struct ConsumerDraft: Hashable, Sendable {
    public var participantId: UUID
    public var weight: Int64
    public var exactMinor: Int64?

    public init(_ participantId: UUID, weight: Int64 = 1, exactMinor: Int64? = nil) {
        self.participantId = participantId
        self.weight = weight
        self.exactMinor = exactMinor
    }
}

public struct PaymentDraft: Hashable, Sendable {
    public var participantId: UUID
    public var amountMinor: Int64
    public var method: String?

    public init(_ participantId: UUID, amountMinor: Int64, method: String? = nil) {
        self.participantId = participantId
        self.amountMinor = amountMinor
        self.method = method
    }
}

public struct ExpenseDraft: Hashable, Sendable {
    public var ledgerId: UUID
    public var merchant: String
    public var note: String?
    public var category: String?
    public var occurredAt: Date
    public var timeZone: String
    public var currency: String
    public var location: Location?
    public var source: ExpenseSource
    public var lines: [LineDraft]
    public var payments: [PaymentDraft]

    public init(ledgerId: UUID, merchant: String, note: String? = nil, category: String? = nil, occurredAt: Date, timeZone: String = TimeZone.current.identifier, currency: String, location: Location? = nil, source: ExpenseSource = .manual, lines: [LineDraft], payments: [PaymentDraft]) {
        self.ledgerId = ledgerId
        self.merchant = merchant
        self.note = note
        self.category = category
        self.occurredAt = occurredAt
        self.timeZone = timeZone
        self.currency = currency
        self.location = location
        self.source = source
        self.lines = lines
        self.payments = payments
    }

    public var totalMinor: Int64 { lines.reduce(0) { $0 + $1.amountMinor } }
}

public struct ExpenseAggregate: Hashable, Sendable {
    public var expense: Expense
    public var lines: [ExpenseLine]
    public var consumers: [LineConsumer]
    public var payments: [ExpensePayment]
    public var journalTx: JournalTx
    public var entries: [JournalEntry]
}

public enum ExpenseBuilder {
    public static func build(_ draft: ExpenseDraft, ledgerParticipantIds: Set<UUID>, actorId: UUID, now: Date = Date(), expenseId: UUID = UUID()) throws -> ExpenseAggregate {
        guard !draft.payments.isEmpty else { throw DomainError.noPayments }
        let paid = draft.payments.reduce(0) { $0 + $1.amountMinor }
        guard paid == draft.totalMinor else { throw DomainError.paymentsMismatch(expected: draft.totalMinor, actual: paid) }
        guard draft.payments.allSatisfy({ $0.amountMinor > 0 }) else { throw DomainError.invalidAmount }
        let referenced = Set(draft.payments.map(\.participantId) + draft.lines.flatMap { $0.consumers.map(\.participantId) })
        if let outsider = referenced.first(where: { !ledgerParticipantIds.contains($0) }) {
            throw DomainError.participantNotInLedger(outsider)
        }

        let expense = Expense(id: expenseId, ledgerId: draft.ledgerId, merchant: draft.merchant, note: draft.note, category: draft.category, occurredAt: draft.occurredAt, timeZone: draft.timeZone, currency: draft.currency, location: draft.location, source: draft.source, createdAt: now, updatedAt: now, version: 1, createdBy: actorId, updatedBy: actorId)

        var lines: [ExpenseLine] = []
        var consumers: [LineConsumer] = []
        for (index, lineDraft) in draft.lines.enumerated() {
            let line = ExpenseLine(id: UUID(), expenseId: expenseId, kind: lineDraft.kind, name: lineDraft.name, quantity: lineDraft.quantity, unitMinor: lineDraft.unitMinor, amountMinor: lineDraft.amountMinor, splitRule: lineDraft.splitRule, sortOrder: Int64(index))
            lines.append(line)
            consumers += lineDraft.consumers.map { LineConsumer(lineId: line.id, participantId: $0.participantId, weight: $0.weight, exactMinor: $0.exactMinor) }
        }
        let payments = draft.payments.map { ExpensePayment(expenseId: expenseId, participantId: $0.participantId, amountMinor: $0.amountMinor, method: $0.method) }

        let allocations = try SplitAllocator.allocate(lines: lines, consumers: consumers)
        let tx = JournalTx(id: UUID(), ledgerId: draft.ledgerId, sourceType: .expense, sourceId: expenseId, occurredAt: draft.occurredAt)
        var entries = payments.map { JournalEntry(id: UUID(), txId: tx.id, participantId: $0.participantId, currency: draft.currency, amountMinor: $0.amountMinor) }
        entries += allocations.map { JournalEntry(id: UUID(), txId: tx.id, participantId: $0.participantId, currency: draft.currency, amountMinor: -$0.owedMinor, lineId: $0.lineId) }

        return ExpenseAggregate(expense: expense, lines: lines, consumers: consumers, payments: payments, journalTx: tx, entries: entries)
    }
}
