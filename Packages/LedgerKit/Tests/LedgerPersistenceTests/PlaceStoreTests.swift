import Foundation
import GRDB
import LedgerDomain
import LedgerPersistence
import Testing

@Test func acceptingProposalWithPlaceUpsertsAndReusesRow() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, _) = try store.createLedger(name: "L", currency: "JPY", myName: "innei")
    let conversation = try store.openConversation(ledgerId: ledger.id)

    let candidate = Candidate(name: "ラスカ熱海店", address: "〒413-0012", latitude: 35.09, longitude: 139.07, providerId: "mkitem-1")

    try store.appendProposal(conversationId: conversation.id, payload: #"{"merchant":"五味八珍","amount":"3135","currency":"JPY","payer":"innei"}"#)
    let first = try #require(try store.writer.read { try Message.filter(Column("kind") == "proposal").fetchOne($0) })
    let firstExpense = try store.acceptProposal(messageId: first.id, ledgerId: ledger.id, place: candidate)
    #expect(firstExpense.placeId != nil)

    try store.appendProposal(conversationId: conversation.id, payload: #"{"merchant":"五味八珍","amount":"2000","currency":"JPY","payer":"innei"}"#)
    let second = try #require(try store.writer.read { try Message.filter(Column("kind") == "proposal" && Column("id") != first.id.uuidString).fetchOne($0) })
    let secondExpense = try store.acceptProposal(messageId: second.id, ledgerId: ledger.id, place: candidate)

    #expect(secondExpense.placeId == firstExpense.placeId)
    let placeCount = try store.writer.read { try Place.fetchCount($0) }
    #expect(placeCount == 1)
}

@Test func acceptingProposalIsAtomicWithPlace() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, _) = try store.createLedger(name: "L", currency: "JPY", myName: "innei")
    let conversation = try store.openConversation(ledgerId: ledger.id)
    try store.appendProposal(conversationId: conversation.id, payload: #"{"merchant":"x","amount":"100","currency":"JPY","payer":"ghost"}"#)
    let proposal = try #require(try store.writer.read { try Message.filter(Column("kind") == "proposal").fetchOne($0) })

    let candidate = Candidate(name: "店", latitude: 35.0, longitude: 139.0, providerId: "p1")
    #expect(throws: ProposalError.unknownMember("ghost")) {
        try store.acceptProposal(messageId: proposal.id, ledgerId: ledger.id, place: candidate)
    }

    let (expenseCount, placeCount) = try store.writer.read { db in
        (try Expense.fetchCount(db), try Place.fetchCount(db))
    }
    #expect(expenseCount == 0)
    #expect(placeCount == 0)
}

@Test func unresolvedPlaceHintIsStoredAsPlaceQuery() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, _) = try store.createLedger(name: "L", currency: "JPY", myName: "innei")
    let conversation = try store.openConversation(ledgerId: ledger.id)
    try store.appendProposal(
        conversationId: conversation.id,
        payload: #"{"merchant":"五味八珍","amount":"3135","currency":"JPY","payer":"innei","place":{"name":"五味八珍","branch":"熱海店"}}"#
    )
    let proposal = try #require(try store.writer.read { try Message.filter(Column("kind") == "proposal").fetchOne($0) })

    let expense = try store.acceptProposal(messageId: proposal.id, ledgerId: ledger.id)
    #expect(expense.placeId == nil)
    let hint = try #require(expense.placeQuery)
    let decoded = try JSONDecoder().decode(PlaceHint.self, from: Data(hint.utf8))
    #expect(decoded.name == "五味八珍")
    #expect(decoded.branch == "熱海店")
}

@Test func setExpensePlaceAssignsAndRemoves() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, me) = try store.createLedger(name: "L", currency: "JPY", myName: "innei")
    let expense = try store.createExpense(ExpenseDraft(
        ledgerId: ledger.id, merchant: "x", occurredAt: Date(), currency: "JPY",
        lines: [LineDraft(name: "x", amountMinor: 100, consumers: [ConsumerDraft(me.id)])],
        payments: [PaymentDraft(me.id, amountMinor: 100)]
    ))

    let candidate = Candidate(name: "店", latitude: 35.0, longitude: 139.0, providerId: "p1")
    try store.setExpensePlace(expenseId: expense.id, candidate: candidate)
    let assigned = try store.writer.read { try Expense.fetchOne($0, key: expense.id.uuidString) }
    #expect(assigned?.placeId != nil)

    try store.setExpensePlace(expenseId: expense.id, candidate: nil)
    let removed = try store.writer.read { try Expense.fetchOne($0, key: expense.id.uuidString) }
    #expect(removed?.placeId == nil)
}

@Test func fetchMapPinsAggregatesExpensesAndTotal() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, me) = try store.createLedger(name: "L", currency: "JPY", settlementCurrency: "CNY", myName: "innei")
    try store.setRates(ledgerId: ledger.id, ["JPY": Decimal(string: "0.05")!], source: .manual)

    let expenseA = try store.createExpense(ExpenseDraft(
        ledgerId: ledger.id, merchant: "麺屋", category: "餐饮", occurredAt: Date(), currency: "JPY",
        lines: [LineDraft(name: "x", amountMinor: 1000, consumers: [ConsumerDraft(me.id)])],
        payments: [PaymentDraft(me.id, amountMinor: 1000)]
    ))
    let expenseB = try store.createExpense(ExpenseDraft(
        ledgerId: ledger.id, merchant: "麺屋 別館", category: "餐饮", occurredAt: Date().addingTimeInterval(60), currency: "JPY",
        lines: [LineDraft(name: "x", amountMinor: 2000, consumers: [ConsumerDraft(me.id)])],
        payments: [PaymentDraft(me.id, amountMinor: 2000)]
    ))
    let candidate = Candidate(name: "麺屋 猪一", latitude: 35.0, longitude: 139.0, providerId: "p1", category: "餐饮")
    try store.setExpensePlace(expenseId: expenseA.id, candidate: candidate)
    try store.setExpensePlace(expenseId: expenseB.id, candidate: candidate)

    let pins = try store.writer.read { try LedgerStore.fetchMapPins($0, ledgerId: ledger.id) }
    #expect(pins.count == 1)
    let pin = try #require(pins.first)
    #expect(pin.expenseCount == 2)
    #expect(pin.dominantCategory == "餐饮")
    #expect(pin.total == Money(minor: 15000, currency: "CNY"))
}
