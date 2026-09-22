import Foundation
import GRDB
import LedgerDomain
import LedgerPersistence
import Testing

@Test func conversationIsReusedPerLedgerAndTurnsPersist() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, _) = try store.createLedger(name: "L", currency: "JPY", myName: "me")
    let first = try store.openConversation(ledgerId: ledger.id)
    #expect(try store.openConversation(ledgerId: ledger.id).id == first.id)

    let (user, assistant) = try store.appendUserTurn(conversationId: first.id, text: "hi")
    try store.updateAssistantTurn(messageId: assistant.id, text: "hello", status: .complete)
    let messages = try store.writer.read { try Message.filter(Column("conversationId") == first.id.uuidString).order(Column("createdAt")).fetchAll($0) }
    #expect(messages.map(\.id) == [user.id, assistant.id])
    #expect(messages[1].text == "hello")
    #expect(messages[1].status == .complete)
}

@Test func interruptedStreamsBecomeFailedOnStartup() throws {
    let queue = try DatabaseQueue()
    let actor = UUID()
    let store = try LedgerStore(writer: queue, actorId: actor)
    let (ledger, _) = try store.createLedger(name: "L", currency: "JPY", myName: "me")
    let conversation = try store.openConversation(ledgerId: ledger.id)
    let (_, assistant) = try store.appendUserTurn(conversationId: conversation.id, text: "hi")

    let reopened = try LedgerStore(writer: queue, actorId: actor)
    let message = try reopened.writer.read { try Message.fetchOne($0, key: assistant.id.uuidString) }
    #expect(message?.status == .failed)
    #expect(message?.error == "interrupted")
}

@Test func acceptingProposalIsIdempotent() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, _) = try store.createLedger(name: "L", currency: "JPY", myName: "innei")
    try store.addParticipant(ledgerId: ledger.id, name: "neko")
    let conversation = try store.openConversation(ledgerId: ledger.id)
    try store.appendProposal(conversationId: conversation.id, payload: #"{"merchant":"布丁","amount":"1800","currency":"JPY","payer":"innei"}"#)
    let proposal = try #require(try store.writer.read { try Message.filter(Column("kind") == "proposal").fetchOne($0) })

    let expense = try store.acceptProposal(messageId: proposal.id, ledgerId: ledger.id)
    #expect(throws: ProposalError.notPending) { try store.acceptProposal(messageId: proposal.id, ledgerId: ledger.id) }
    try store.dismissProposal(messageId: proposal.id)

    let (count, stored) = try store.writer.read { db in (try Expense.fetchCount(db), try Message.fetchOne(db, key: proposal.id.uuidString)) }
    #expect(count == 1)
    #expect(stored?.proposalState == .accepted)
    #expect(stored?.expenseId == expense.id)
}

@Test func invalidProposalWritesNothing() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, _) = try store.createLedger(name: "L", currency: "JPY", myName: "innei")
    let conversation = try store.openConversation(ledgerId: ledger.id)
    try store.appendProposal(conversationId: conversation.id, payload: #"{"merchant":"x","amount":"100","currency":"JPY","payer":"ghost"}"#)
    let proposal = try #require(try store.writer.read { try Message.filter(Column("kind") == "proposal").fetchOne($0) })

    #expect(throws: ProposalError.unknownMember("ghost")) { try store.acceptProposal(messageId: proposal.id, ledgerId: ledger.id) }
    try store.dismissProposal(messageId: proposal.id)
    let (count, stored) = try store.writer.read { db in (try Expense.fetchCount(db), try Message.fetchOne(db, key: proposal.id.uuidString)) }
    #expect(count == 0)
    #expect(stored?.proposalState == .dismissed)
}
