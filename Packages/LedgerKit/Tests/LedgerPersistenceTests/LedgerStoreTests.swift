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
