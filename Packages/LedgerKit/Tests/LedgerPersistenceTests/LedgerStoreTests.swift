import Foundation
import GRDB
import LedgerDomain
import LedgerPersistence
import Testing

@Test func createExpensePersistsAggregateAndBalances() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, me) = try store.createLedger(name: "Japan 2026", currency: "JPY", myName: "Innei")
    let a = try store.addParticipant(ledgerId: ledger.id, name: "A")
    let guest = try store.addParticipant(ledgerId: ledger.id, name: "Guest")

    try store.createExpense(ExpenseDraft(
        ledgerId: ledger.id, merchant: "焼肉 弘", occurredAt: Date(), currency: "JPY",
        lines: [LineDraft(name: "合計", amountMinor: 3000, consumers: [ConsumerDraft(me.id), ConsumerDraft(a.id), ConsumerDraft(guest.id)])],
        payments: [PaymentDraft(me.id, amountMinor: 3000)]
    ))

    let activity = try store.writer.read { try LedgerStore.fetchActivity($0, ledgerId: ledger.id) }
    #expect(activity.count == 1)
    #expect(activity[0].totalMinor == 3000)
    #expect(activity[0].payerNames == "Innei")
    #expect(activity[0].consumerCount == 3)

    let balances = try store.writer.read { try LedgerStore.fetchBalances($0, ledgerId: ledger.id) }
    let net = Dictionary(uniqueKeysWithValues: balances.map { ($0.participantId, $0.netMinor) })
    #expect(net[me.id] ?? .min == 2000)
    #expect(net[a.id] ?? .min == -1000)
    #expect(net[guest.id] ?? .min == -1000)
    #expect(balances.reduce(0) { $0 + $1.netMinor } == 0)
}

@Test func failedValidationRollsBack() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, me) = try store.createLedger(name: "L", currency: "USD", myName: "Me")
    let outsider = UUID()
    #expect(throws: DomainError.participantNotInLedger(outsider)) {
        try store.createExpense(ExpenseDraft(
            ledgerId: ledger.id, merchant: "x", occurredAt: Date(), currency: "USD",
            lines: [LineDraft(name: "x", amountMinor: 100, consumers: [ConsumerDraft(outsider)])],
            payments: [PaymentDraft(me.id, amountMinor: 100)]
        ))
    }
    let count = try store.writer.read { try Expense.fetchCount($0) }
    #expect(count == 0)
}

@Test func expenseDetailShowsPaymentsSharesAndConversion() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, me) = try store.createLedger(name: "L", currency: "JPY", settlementCurrency: "CNY", myName: "Innei")
    let a = try store.addParticipant(ledgerId: ledger.id, name: "A")
    let expense = try store.createExpense(ExpenseDraft(
        ledgerId: ledger.id, merchant: "麺屋 猪一", occurredAt: Date(), currency: "JPY",
        lines: [
            LineDraft(name: "ラーメン", amountMinor: 2000, consumers: [ConsumerDraft(me.id), ConsumerDraft(a.id)]),
            LineDraft(name: "ビール", amountMinor: 700, consumers: [ConsumerDraft(a.id)]),
        ],
        payments: [PaymentDraft(me.id, amountMinor: 2700, method: "card")]
    ))
    try store.setRates(ledgerId: ledger.id, ["JPY": Decimal(string: "0.043")!], source: .manual)

    let detail = try #require(try store.writer.read { try LedgerStore.fetchExpenseDetail($0, expenseId: expense.id) })
    #expect(detail.total.minor == 2700)
    #expect(detail.lines.map(\.name) == ["ラーメン", "ビール"])
    #expect(detail.payments.map(\.participantName) == ["Innei"])
    #expect(detail.payments.first?.method == "card")
    #expect(detail.shares.map(\.participantName) == ["A", "Innei"])
    #expect(detail.shares.map(\.owedMinor) == [1700, 1000])
    #expect(detail.settled(2700) == Money(minor: 11610, currency: "CNY"))
}
