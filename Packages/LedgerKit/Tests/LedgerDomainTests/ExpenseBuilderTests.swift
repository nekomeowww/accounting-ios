import Foundation
import LedgerDomain
import Testing

private let ledger = UUID()
private let me = UUID(), a = UUID(), b = UUID(), c = UUID()
private let actor = UUID()

private func draft(lines: [LineDraft], payments: [PaymentDraft]) -> ExpenseDraft {
    ExpenseDraft(ledgerId: ledger, merchant: "焼肉 弘", occurredAt: Date(), currency: "JPY", lines: lines, payments: payments)
}

@Test func journalBalancesToZeroAndPayerIsOwed() throws {
    let d = draft(
        lines: [LineDraft(name: "合計", amountMinor: 18420, consumers: [me, a, b, c].map { ConsumerDraft($0) })],
        payments: [PaymentDraft(me, amountMinor: 18420)]
    )
    let agg = try ExpenseBuilder.build(d, ledgerParticipantIds: [me, a, b, c], actorId: actor)
    #expect(agg.entries.reduce(0) { $0 + $1.amountMinor } == 0)
    let net = Dictionary(grouping: agg.entries, by: \.participantId).mapValues { $0.reduce(0) { $0 + $1.amountMinor } }
    #expect(net[me] ?? .min == 18420 - 4605)
    #expect(net[a]! + net[b]! + net[c]! == -(18420 - 4605))
}

@Test func treatLeavesOthersAtZero() throws {
    let d = draft(
        lines: [LineDraft(name: "合計", amountMinor: 1000, consumers: [ConsumerDraft(me), ConsumerDraft(a, weight: 0)])],
        payments: [PaymentDraft(me, amountMinor: 1000)]
    )
    let agg = try ExpenseBuilder.build(d, ledgerParticipantIds: [me, a], actorId: actor)
    let net = Dictionary(grouping: agg.entries, by: \.participantId).mapValues { $0.reduce(0) { $0 + $1.amountMinor } }
    #expect(net[me] ?? .min == 0)
    #expect(net[a] ?? .min == 0)
    #expect(agg.consumers.count == 2)
}

@Test func paymentsMustMatchLines() {
    let d = draft(lines: [LineDraft(name: "x", amountMinor: 100, consumers: [ConsumerDraft(me)])], payments: [PaymentDraft(me, amountMinor: 90)])
    #expect(throws: DomainError.paymentsMismatch(expected: 100, actual: 90)) {
        try ExpenseBuilder.build(d, ledgerParticipantIds: [me], actorId: actor)
    }
}

@Test func outsiderIsRejected() {
    let d = draft(lines: [LineDraft(name: "x", amountMinor: 100, consumers: [ConsumerDraft(a)])], payments: [PaymentDraft(me, amountMinor: 100)])
    #expect(throws: DomainError.participantNotInLedger(a)) {
        try ExpenseBuilder.build(d, ledgerParticipantIds: [me], actorId: actor)
    }
}
