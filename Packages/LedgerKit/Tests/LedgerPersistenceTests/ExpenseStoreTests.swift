import Foundation
import GRDB
import LedgerDomain
import LedgerPersistence
import Testing

private func net(_ store: LedgerStore, _ ledger: UUID) throws -> [UUID: Int64] {
    let balances = try store.writer.read { try LedgerStore.fetchBalances($0, ledgerId: ledger) }
    return Dictionary(uniqueKeysWithValues: balances.map { ($0.participantId, $0.netMinor) })
}

@Test func editDeleteAndRestoreKeepBalancesConsistent() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, me) = try store.createLedger(name: "L", currency: "JPY", myName: "innei")
    let white = try store.addParticipant(ledgerId: ledger.id, name: "whitewater")
    let expense = try store.createExpense(ExpenseDraft(
        ledgerId: ledger.id, merchant: "麵屋優光", occurredAt: Date(), currency: "JPY",
        lines: [
            LineDraft(name: "鶏白湯", amountMinor: 1250, consumers: [ConsumerDraft(me.id)]),
            LineDraft(name: "淡竹", amountMinor: 900, consumers: [ConsumerDraft(white.id)]),
            LineDraft(name: "餃子", amountMinor: 430, consumers: [ConsumerDraft(me.id), ConsumerDraft(white.id)]),
        ],
        payments: [PaymentDraft(me.id, amountMinor: 2580)]
    ))
    #expect(try net(store, ledger.id)[white.id] == -1115)

    var editable = try store.editableExpense(id: expense.id)
    #expect(editable.draft.lines.map(\.name) == ["鶏白湯", "淡竹", "餃子"])
    #expect(editable.draft.lines[2].consumers.count == 2)
    let original = editable
    editable.draft.merchant = "麵屋優光 四条"
    editable.draft.payments = [PaymentDraft(white.id, amountMinor: 2580)]
    let version = try store.updateExpense(id: expense.id, editable.draft, expectedVersion: editable.version)
    #expect(try net(store, ledger.id)[me.id] == -1465)
    #expect(throws: ExpenseStoreError.versionConflict) {
        try store.updateExpense(id: expense.id, original.draft, expectedVersion: original.version)
    }

    try store.updateExpense(id: expense.id, original.draft, expectedVersion: version)
    #expect(try net(store, ledger.id)[white.id] == -1115)

    try store.deleteExpense(id: expense.id)
    #expect(try net(store, ledger.id).values.allSatisfy { $0 == 0 })
    #expect(try store.writer.read { try LedgerStore.fetchActivity($0, ledgerId: ledger.id) }.isEmpty)
    #expect(throws: ExpenseStoreError.notFound) { try store.editableExpense(id: expense.id) }

    try store.restoreExpense(id: expense.id)
    #expect(try net(store, ledger.id)[white.id] == -1115)
    #expect(try store.editableExpense(id: expense.id).draft.lines.map(\.amountMinor) == [1250, 900, 430])
}
