import Foundation
import GRDB
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
