import Foundation
import GRDB
import LedgerDomain
@testable import LedgerPersistence
import Testing

private let proposalArgs = #"{"merchant":"晚饭","amount":"12.50","currency":"USD","payer":"me"}"#
private func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}
private func object(_ text: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
}
private func assistant(_ args: [String] = [], text: String = "", stop: String = "toolUse", tool: String = "propose_expense") throws -> String {
    var content: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
    content += try args.enumerated().map { ["type": "toolCall", "id": "call-\($0.offset)", "name": tool, "arguments": try object($0.element)] }
    return try json(["role": "assistant", "content": content, "api": "openai-completions", "provider": "openai", "model": "fixture",
                     "stopReason": stop, "timestamp": 1,
                     "usage": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0,
                               "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]])
}
private func setup(_ store: LedgerStore) throws -> (UUID, UUID, PreparedAgentRun) {
    let (ledger, _) = try store.createLedger(name: "Test", currency: "USD", myName: "me")
    let conversation = try store.openConversation(ledgerId: ledger.id)
    let prepared = try store.beginAgentRun(conversationId: conversation.id, text: "晚饭 12.50")
    return (ledger.id, conversation.id, prepared)
}
private func tool(_ store: LedgerStore, _ prepared: PreparedAgentRun, index: Int = 0, args: String = proposalArgs) throws -> AgentToolExecution {
    try store.executeAgentProposal(conversationId: prepared.run.conversationId, runId: prepared.run.id,
                                   assistantMessageId: prepared.run.id.uuidString + ":1", toolCallId: "call-\(index)", arguments: args)
}

@Test func failedRunWithoutTextOffersDurableRetry() throws {
    let store = try LedgerStore.inMemory()
    let (_, conversation, prepared) = try setup(store)
    try store.finishAgentRun(conversationId: conversation, runId: prepared.run.id, status: .failed, error: "HTTP 401")
    let messages = try store.writer.read { db in
        try Message.filter(Column("conversationId") == conversation.uuidString).fetchAll(db)
    }
    let failure = try #require(messages.first { $0.role == .assistant })
    #expect(failure.status == .failed)
    #expect(failure.error == "HTTP 401")
    #expect(failure.agentRunId == prepared.run.id)
    let resumed = try #require(try store.resumeAgentRun(runId: prepared.run.id))
    #expect(resumed.inputJSON == nil)
}

@Test func v4DatabaseMigratesWithoutReplacingExistingMessages() throws {
    let queue = try DatabaseQueue()
    try Migrations.migrator.migrate(queue, upTo: "v4")
    let ledger = UUID(), conversation = UUID(), message = UUID(), actor = UUID()
    let now = Date()
    try queue.write { db in
        try db.execute(sql: "INSERT INTO ledger (id,name,type,defaultCurrency,settlementCurrency,createdAt,updatedAt,version,createdBy,updatedBy) VALUES (?,'Existing','trip','USD','USD',?,?,1,?,?)",
                       arguments: [ledger.uuidString, now, now, actor.uuidString, actor.uuidString])
        try db.execute(sql: "INSERT INTO conversation (id,ledgerId,createdAt,updatedAt) VALUES (?,?,?,?)",
                       arguments: [conversation.uuidString, ledger.uuidString, now, now])
        try db.execute(sql: "INSERT INTO message (id,conversationId,role,text,status,createdAt,updatedAt) VALUES (?,?,'user','existing message','complete',?,?)",
                       arguments: [message.uuidString, conversation.uuidString, now, now])
    }
    let store = try LedgerStore(writer: queue, actorId: actor)
    let prepared = try store.beginAgentRun(conversationId: conversation, text: "new")
    #expect(prepared.historyJSON.contains("existing message"))
    #expect(try queue.read { try Message.fetchOne($0, key: message.uuidString)?.text } == "existing message")
    #expect(try queue.read { try Message.fetchCount($0) } == 2)
}

@Test func agentToolDeliveryIsAtomicAndConcurrentDuplicatesReturnSameCard() async throws {
    let store = try LedgerStore.inMemory()
    let (ledger, conversation, prepared) = try setup(store)
    let input = try object(#require(prepared.inputJSON))
    try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id,
                                    id: input["id"] as! String, payload: json(input["message"]!))
    #expect(try store.agentTranscript(conversationId: conversation).count == 1)
    let assistantId = prepared.run.id.uuidString + ":1"
    let payload = try assistant([proposalArgs])
    try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id, id: assistantId, payload: payload)
    let cards = try await withThrowingTaskGroup(of: UUID.self) { group in
        for _ in 0..<4 { group.addTask { try #require(try tool(store, prepared).proposalId) } }
        var cards: [UUID] = []
        for try await card in group { cards.append(card) }
        return cards
    }
    #expect(Set(cards).count == 1)
    let result = try tool(store, prepared)
    #expect(try await store.writer.read { try Expense.fetchCount($0) } == 0)
    try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id,
                                    id: prepared.run.id.uuidString + ":2", payload: result.resultJSON)
    try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id,
                                    id: prepared.run.id.uuidString + ":3", payload: assistant(text: "待确认", stop: "stop"))
    try store.finishAgentRun(conversationId: conversation, runId: prepared.run.id, status: .complete)
    #expect(try await store.writer.read { try Message.filter(Column("kind") == "proposal").fetchCount($0) } == 1)
    #expect(try store.agentTranscript(conversationId: conversation).map(\.sequence) == [1, 2, 3, 4])
    let proposalId = try #require(result.proposalId)
    try store.acceptProposal(messageId: proposalId, ledgerId: ledger)
    #expect(throws: ProposalError.notPending) { try store.acceptProposal(messageId: proposalId, ledgerId: ledger) }
    #expect(try await store.writer.read { try Expense.fetchCount($0) } == 1)
    #expect(try store.agentProposalContext(conversationId: conversation).contains("accepted"))
}

@Test func itemizedToolCreatesOneCardAndAcceptsOneExpense() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, conversation, prepared) = try setup(store)
    try store.addParticipant(ledgerId: ledger, name: "whitewater")
    let args = #"{"merchant":"麵屋優光","amount":"2580","currency":"JPY","payer":"me","items":[{"name":"拉面","amount":"1250","consumers":["me"]},{"name":"淡竹","amount":"900","consumers":["whitewater"]},{"name":"饺子","amount":"430","consumers":["me","whitewater"]}]}"#
    try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id,
                                    id: prepared.run.id.uuidString + ":1", payload: assistant([args]))
    let card = try #require(try tool(store, prepared, args: args).proposalId)
    #expect(try store.writer.read { try Message.filter(Column("kind") == "proposal").fetchCount($0) } == 1)
    #expect(try store.writer.read { try Expense.fetchCount($0) } == 0)
    let expense = try store.acceptProposal(messageId: card, ledgerId: ledger)
    #expect(try store.writer.read { try Expense.fetchCount($0) } == 1)
    let lines = try store.writer.read { try ExpenseLine.filter(Column("expenseId") == expense.id.uuidString).order(Column("sortOrder")).fetchAll($0) }
    #expect(lines.map(\.name) == ["拉面", "淡竹", "饺子"])
    #expect(lines.map(\.amountMinor) == [1250, 900, 430])
    #expect(throws: ProposalError.notPending) { try store.acceptProposal(messageId: card, ledgerId: ledger) }
}

@Test func toolRecordFailureRollsBackCardAndAllowsSafeRetry() throws {
    let store = try LedgerStore.inMemory()
    let (_, conversation, prepared) = try setup(store)
    try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id,
                                    id: prepared.run.id.uuidString + ":1", payload: assistant([proposalArgs]))
    try store.writer.write { try $0.execute(sql: "CREATE TRIGGER fail_tool BEFORE INSERT ON agentToolExecution BEGIN SELECT RAISE(ABORT, 'disk full'); END") }
    #expect(throws: (any Error).self) { try tool(store, prepared) }
    #expect(try store.writer.read { try Message.filter(Column("kind") == "proposal").fetchCount($0) } == 0)
    try store.writer.write { try $0.execute(sql: "DROP TRIGGER fail_tool") }
    #expect(try tool(store, prepared).proposalId != nil)
}

@Test func diskReopenRepairsCommittedToolsAndDoesNotRepeatUserOrCard() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("ledger.sqlite")
    let actor = UUID()
    let saved: (UUID, UUID, UUID) = try autoreleasepool {
        let store = try LedgerStore.onDisk(at: path, actorId: actor)
        let (_, conversation, prepared) = try setup(store)
        try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id,
                                        id: prepared.run.id.uuidString + ":1", payload: assistant([proposalArgs, proposalArgs]))
        #expect(throws: AgentStoreError.invalidMessage) { try tool(store, prepared, index: 1) }
        let card = try #require(try tool(store, prepared).proposalId)
        // Commit card 1, but lose its JS reply. Tool 2 has not executed yet.
        return (conversation, prepared.run.id, card)
    }
    let reopened = try LedgerStore.onDisk(at: path, actorId: actor)
    #expect(try reopened.writer.read { try AgentRunRecord.fetchOne($0, key: saved.1.uuidString)?.status } == .interrupted)
    let retryable = { try reopened.writer.read { try Message.filter(Column("agentRunId") == saved.1.uuidString && Column("status") == "failed").fetchCount($0) } }
    #expect(try retryable() == 1)
    let recovered = try #require(try reopened.resumeAgentRun(runId: saved.1))
    #expect(recovered.inputJSON == nil)
    let history = try JSONSerialization.jsonObject(with: Data(recovered.historyJSON.utf8)) as! [[String: Any]]
    #expect(history.compactMap { ($0["message"] as? [String: Any])?["role"] as? String } == ["user", "assistant", "toolResult", "toolResult"])
    let cards = try reopened.writer.read { try Message.filter(Column("kind") == "proposal").fetchAll($0) }
    #expect(cards.count == 2)
    #expect(cards.contains { $0.id == saved.2 })
    #expect(try reopened.writer.read { try Message.filter(Column("role") == "user").fetchCount($0) } == 1)
    #expect(try retryable() == 0)
    #expect(throws: AgentStoreError.busy) { try reopened.resumeAgentRun(runId: saved.1) }
}

@Test func partialAssistantIsKeptForDisplayButExcludedFromResumedContext() throws {
    let store = try LedgerStore.inMemory()
    let (_, conversation, prepared) = try setup(store)
    try store.updateAgentText(conversationId: conversation, runId: prepared.run.id, messageId: prepared.run.id.uuidString + ":1", text: "部分回复")
    try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id,
                                    id: prepared.run.id.uuidString + ":1", payload: assistant(text: "部分回复", stop: "aborted"))
    try store.finishAgentRun(conversationId: conversation, runId: prepared.run.id, status: .aborted)
    let recovered = try #require(try store.resumeAgentRun(runId: prepared.run.id))
    #expect(!recovered.historyJSON.contains("部分回复"))
    #expect(try store.writer.read { try Message.filter(Column("text") == "部分回复").fetchOne($0)?.status } == .failed)
    #expect(throws: AgentStoreError.staleRun) {
        try store.updateAgentText(conversationId: conversation, runId: prepared.run.id, messageId: prepared.run.id.uuidString + ":1", text: "late")
    }
}

@Test func badToolsAreDurableErrorsAndCannotTargetAnotherLedger() throws {
    let store = try LedgerStore.inMemory()
    let (_, conversation, prepared) = try setup(store)
    let bad = proposalArgs.replacingOccurrences(of: "\"me\"", with: "\"ghost\"")
    try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id,
                                    id: prepared.run.id.uuidString + ":1", payload: assistant([bad]))
    let failure = try tool(store, prepared, args: bad)
    #expect(failure.isError && failure.proposalId == nil)
    #expect(failure.errorMessage?.contains("ghost") == true)
    #expect(throws: AgentStoreError.identityConflict) { try tool(store, prepared, args: proposalArgs) }
    #expect(try store.writer.read { try Message.filter(Column("kind") == "proposal").fetchCount($0) } == 0)
    try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id,
                                    id: prepared.run.id.uuidString + ":2", payload: failure.resultJSON)
    let (other, _) = try store.createLedger(name: "Other", currency: "USD", myName: "me")
    let otherConversation = try store.openConversation(ledgerId: other.id)
    #expect(throws: AgentStoreError.staleRun) {
        try store.executeAgentProposal(conversationId: otherConversation.id, runId: prepared.run.id,
                                       assistantMessageId: prepared.run.id.uuidString + ":1", toolCallId: "call-0", arguments: bad)
    }
    try store.appendProposal(conversationId: conversation, payload: proposalArgs)
    let card = try #require(try store.writer.read { try Message.filter(Column("kind") == "proposal").fetchOne($0) })
    #expect(throws: ProposalError.notPending) { try store.acceptProposal(messageId: card.id, ledgerId: other.id) }
    #expect(try store.writer.read { try Expense.fetchCount($0) } == 0)
}

@Test func runOwnershipMessageIdentityAndToolOrderAreEnforced() throws {
    let store = try LedgerStore.inMemory()
    let (_, conversation, prepared) = try setup(store)
    #expect(throws: AgentStoreError.busy) { try store.beginAgentRun(conversationId: conversation, text: "concurrent") }
    let id = prepared.run.id.uuidString + ":1"
    try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id, id: id, payload: assistant([proposalArgs]))
    #expect(throws: AgentStoreError.identityConflict) {
        try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id, id: id, payload: assistant(text: "changed", stop: "stop"))
    }
    #expect(throws: AgentStoreError.needsRecovery) { try store.finishAgentRun(conversationId: conversation, runId: prepared.run.id, status: .complete) }
    #expect(throws: AgentStoreError.invalidMessage) {
        try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id, id: prepared.run.id.uuidString + ":3", payload: assistant(text: "skipped tool", stop: "stop"))
    }
    try store.finishAgentRun(conversationId: conversation, runId: prepared.run.id, status: .failed)
    #expect(throws: AgentStoreError.needsRecovery) { try store.beginAgentRun(conversationId: conversation, text: "next") }
}

@Test func legacyImportIsOnceOnlyAndFinalCheckpointNeedsNoModelRetry() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, _) = try store.createLedger(name: "Old", currency: "USD", myName: "me")
    let conversation = try store.openConversation(ledgerId: ledger.id)
    let (_, oldAssistant) = try store.appendUserTurn(conversationId: conversation.id, text: "old")
    try store.updateAssistantTurn(messageId: oldAssistant.id, text: "old answer", status: .complete)
    try store.appendProposal(conversationId: conversation.id, payload: proposalArgs)
    let prepared = try store.beginAgentRun(conversationId: conversation.id, text: "new")
    #expect(prepared.historyJSON.contains("历史记账卡片"))
    #expect(!prepared.historyJSON.contains("toolCall"))
    try store.checkpointAgentMessage(conversationId: conversation.id, runId: prepared.run.id,
                                    id: prepared.run.id.uuidString + ":1", payload: assistant(text: "finished", stop: "stop"))
    // Simulate process exit after the final checkpoint but before the terminal status write.
    let reopened = try LedgerStore(writer: store.writer, actorId: store.actorId)
    #expect(try reopened.resumeAgentRun(runId: prepared.run.id) == nil)
    #expect(try reopened.writer.read { try AgentRunRecord.fetchOne($0, key: prepared.run.id.uuidString)?.status } == .complete)
    let next = try reopened.beginAgentRun(conversationId: conversation.id, text: "next")
    #expect(try reopened.agentTranscript(conversationId: conversation.id).count == 6)
    #expect(next.historyJSON.contains("old answer"))
}

@Test func repaymentToolCreatesCardAndAcceptRecordsTransfer() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, conversation, prepared) = try setup(store)
    _ = try store.addParticipant(ledgerId: ledger, name: "whitewater")
    let args = #"{"from":"me","to":"whitewater","amount":"20","currency":"USD","note":"微信"}"#
    try store.checkpointAgentMessage(conversationId: conversation, runId: prepared.run.id,
                                    id: prepared.run.id.uuidString + ":1", payload: assistant([args], tool: "propose_repayment"))
    let card = try #require(try tool(store, prepared, args: args).proposalId)
    #expect(try store.writer.read { try Message.fetchOne($0, key: card.uuidString)?.kind } == .repayment)
    #expect(try store.writer.read { try LedgerStore.fetchBalances($0, ledgerId: ledger) }.isEmpty)

    try store.acceptRepayment(messageId: card, ledgerId: ledger)
    let net = Dictionary(uniqueKeysWithValues: try store.writer.read { try LedgerStore.fetchBalances($0, ledgerId: ledger) }.map { ($0.participantName, $0.netMinor) })
    #expect(net == ["me": 2000, "whitewater": -2000])
    #expect(throws: ProposalError.notPending) { try store.acceptRepayment(messageId: card, ledgerId: ledger) }

    #expect(try tool(store, prepared, args: args).proposalId == card)
}

@Test func repaymentRejectsSamePerson() throws {
    #expect(throws: ProposalError.samePerson) {
        try RepaymentProposal.decode(#"{"from":"a","to":"A","amount":"1","currency":"USD"}"#).resolve(participants: [(UUID(), "a")])
    }
}
