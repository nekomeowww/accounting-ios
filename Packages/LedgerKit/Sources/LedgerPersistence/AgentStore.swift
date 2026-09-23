import Foundation
import GRDB
import LedgerDomain

public enum AgentRunStatus: String, Codable, Sendable { case running, complete, failed, aborted, interrupted }

public struct AgentRunRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "agentRun"
    public var id: UUID
    public var conversationId: UUID
    public var userMessageId: UUID
    public var status: AgentRunStatus
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

public struct AgentTranscriptEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "agentTranscript"
    public var conversationId: UUID
    public var id: String
    public var sequence: Int
    public var runId: UUID?
    public var sourceMessageId: String?
    public var formatVersion: Int = 1
    public var payload: String
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .uppercaseString }
}

public struct PreparedAgentRun: Sendable {
    public let run: AgentRunRecord
    public let historyJSON: String
    /// nil means continue from the restored user/toolResult tail, without adding another user input.
    public let inputJSON: String?
}

public struct AgentImage: Sendable {
    public var mimeType: String
    public var data: Data
    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }
}

public struct AgentToolExecution: Sendable {
    public let resultJSON: String
    public let proposalId: UUID?
    public let isError: Bool
    public let errorMessage: String?
}

public enum AgentStoreError: Error, Equatable, Sendable, LocalizedError {
    case busy, staleRun, invalidMessage, identityConflict, needsRecovery, cannotResume
    public var errorDescription: String? {
        switch self {
        case .busy: "这个会话正在运行"
        case .staleRun: "这次运行已经结束或不属于当前会话"
        case .invalidMessage: "Agent 消息格式或顺序无效"
        case .identityConflict: "同一条 Agent 消息或工具调用的内容发生冲突"
        case .needsRecovery: "上一轮工具调用尚未完成，请先重试恢复"
        case .cannotResume: "这次运行已完成，或已有后续对话，不能继续"
        }
    }
}

extension LedgerStore {
    public func beginAgentRun(conversationId: UUID, text: String, images: [AgentImage] = []) throws -> PreparedAgentRun {
        guard images.count > 0 || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentStoreError.invalidMessage }
        return try writer.write { db in
            try Self.requireIdle(db, conversationId)
            try Self.importAgentHistory(db, conversationId)
            let history = try Self.contextEntries(Self.transcript(db, conversationId))
            guard try Self.pendingCalls(history).isEmpty else { throw AgentStoreError.needsRecovery }
            let now = Date()
            let user = Message(id: UUID(), conversationId: conversationId, role: .user, text: text,
                               status: .complete, createdAt: now, updatedAt: now)
            try user.insert(db)
            var content: [[String: Any]] = []
            for image in images {
                let id = UUID()
                try db.execute(sql: "INSERT INTO messageImage (id, messageId, mimeType, data, createdAt) VALUES (?, ?, ?, ?, ?)",
                               arguments: [id.uuidString, user.id.uuidString, image.mimeType, image.data, now])
                content.append(["type": "image", "mimeType": image.mimeType, "imageId": id.uuidString])
            }
            if !text.isEmpty { content.append(["type": "text", "text": text]) }
            let run = AgentRunRecord(id: UUID(), conversationId: conversationId, userMessageId: user.id,
                                     status: .running, createdAt: now, updatedAt: now)
            try run.insert(db)
            let payload = try AgentJSON.encode(["role": "user", "content": images.isEmpty ? text as Any : content, "timestamp": now.timeIntervalSince1970 * 1000])
            try Self.insertTranscript(db, conversationId, id: user.id.uuidString, runId: run.id, payload: payload)
            try db.execute(sql: "UPDATE message SET agentRunId = ?, agentMessageId = ? WHERE id = ?",
                           arguments: [run.id.uuidString, user.id.uuidString, user.id.uuidString])
            try Self.touchConversation(db, conversationId)
            let input = try Self.modelMessage(db, AgentJSON.object(payload), inlineImages: true)
            return PreparedAgentRun(run: run, historyJSON: try Self.historyJSON(db, history, inlineFor: nil),
                                    inputJSON: try AgentJSON.encode(["id": user.id.uuidString, "message": input]))
        }
    }

    public func messageImages(messageId: UUID) throws -> [Data] {
        try writer.read { db in
            try Data.fetchAll(db, sql: "SELECT data FROM messageImage WHERE messageId = ? ORDER BY rowid", arguments: [messageId.uuidString])
        }
    }

    public func agentTranscript(conversationId: UUID) throws -> [AgentTranscriptEntry] {
        try writer.read { try Self.transcript($0, conversationId) }
    }

    /// Complete pi messages only. UI partial text is stored separately and never used to execute tools.
    public func checkpointAgentMessage(conversationId: UUID, runId: UUID, id: String, payload: String) throws {
        let object = try AgentJSON.message(payload)
        let canonical = try AgentJSON.encode(object)
        try writer.write { db in
            let run = try Self.activeRun(db, conversationId, runId)
            let entries = try Self.transcript(db, conversationId)
            if let existing = entries.first(where: { $0.id == id }) {
                guard existing.runId == run.id, try AgentJSON.identity(existing.payload) == AgentJSON.identity(canonical) else { throw AgentStoreError.identityConflict }
                return
            }
            guard !id.isEmpty, id.hasPrefix(runId.uuidString + ":") else { throw AgentStoreError.invalidMessage }
            let role = object["role"] as! String
            guard role != "user" else { throw AgentStoreError.invalidMessage } // user was committed by beginAgentRun
            var sourceId: String?
            if role == "toolResult" {
                let callId = object["toolCallId"] as! String
                guard let source = try entries.reversed().first(where: { entry in
                    try AgentJSON.calls(entry.payload).contains(where: { $0.id == callId })
                }), let call = try AgentJSON.calls(source.payload).first(where: { $0.id == callId }),
                      call.name == object["toolName"] as? String else { throw AgentStoreError.invalidMessage }
                guard try !entries.contains(where: { entry in
                    try entry.sourceMessageId == source.id && AgentJSON.object(entry.payload)["toolCallId"] as? String == callId
                }) else { throw AgentStoreError.identityConflict }
                sourceId = source.id
                if let stored = try Self.execution(db, conversationId, source.id, callId) {
                    let committed = try AgentJSON.object(stored.resultJSON)
                    guard try AgentJSON.resultBody(committed) == AgentJSON.resultBody(object) else { throw AgentStoreError.identityConflict }
                } else {
                    // pi may reject unknown tools or invalid arguments before calling Swift.
                    guard object["isError"] as? Bool == true else { throw AgentStoreError.invalidMessage }
                    try Self.saveExecution(db, conversationId, source.id, call, result: canonical, proposalId: nil)
                }
            }
            let entry = AgentTranscriptEntry(conversationId: conversationId, id: id, sequence: 0, runId: runId,
                                             sourceMessageId: sourceId, payload: canonical)
            _ = try Self.pendingCalls(Self.contextEntries(entries + [entry]))
            try Self.insertTranscript(db, conversationId, id: id, runId: runId, source: sourceId, payload: canonical)
            if role == "assistant" {
                let failed = AgentJSON.incomplete(object)
                try Self.projectText(db, run, id: id, text: AgentJSON.text(object), status: failed ? .failed : .complete,
                                     error: failed ? (object["errorMessage"] as? String ?? "interrupted") : nil)
            }
            try Self.touchConversation(db, conversationId)
        }
    }

    public func updateAgentText(conversationId: UUID, runId: UUID, messageId: String, text: String) throws {
        try writer.write { db in
            let run = try Self.activeRun(db, conversationId, runId)
            guard messageId.hasPrefix(runId.uuidString + ":"),
                  try AgentTranscriptEntry.filter(Column("conversationId") == conversationId.uuidString && Column("id") == messageId).fetchCount(db) == 0 else {
                throw AgentStoreError.staleRun
            }
            try Self.projectText(db, run, id: messageId, text: text, status: .streaming)
        }
    }

    /// The caller must throw errorMessage back to pi when isError is true; never turn a storage error into tool success.
    public func executeAgentProposal(conversationId: UUID, runId: UUID, assistantMessageId: String,
                                     toolCallId: String, arguments: String, timeZone: TimeZone = .current) throws -> AgentToolExecution {
        let canonical = try AgentJSON.encode(AgentJSON.object(arguments))
        return try writer.write { db in
            _ = try Self.activeRun(db, conversationId, runId)
            guard let source = try Self.transcript(db, conversationId).first(where: { $0.id == assistantMessageId }),
                  source.runId == runId, !AgentJSON.incomplete(try AgentJSON.object(source.payload)),
                  let call = try AgentJSON.calls(source.payload).first(where: { $0.id == toolCallId }),
                  Self.cardTools.contains(call.name), call.arguments == canonical else { throw AgentStoreError.identityConflict }
            return try Self.performProposal(db, conversationId, source.id, call, actorId: actorId, timeZone: timeZone)
        }
    }

    public func finishAgentRun(conversationId: UUID, runId: UUID, status: AgentRunStatus, error: String? = nil) throws {
        guard [.complete, .failed, .aborted].contains(status) else { throw AgentStoreError.invalidMessage }
        try writer.write { db in
            guard let run = try AgentRunRecord.fetchOne(db, key: runId.uuidString), run.conversationId == conversationId else { throw AgentStoreError.staleRun }
            if run.status == status { return }
            guard run.status == .running else { throw AgentStoreError.staleRun }
            if status == .complete {
                let entries = try Self.transcript(db, conversationId)
                guard let last = entries.last, !AgentJSON.incomplete(try AgentJSON.object(last.payload)),
                      (try AgentJSON.object(last.payload))["role"] as? String != "user",
                      try Self.pendingCalls(Self.contextEntries(entries)).isEmpty else { throw AgentStoreError.needsRecovery }
            }
            try db.execute(sql: "UPDATE agentRun SET status = ?, error = ?, updatedAt = ? WHERE id = ?",
                           arguments: [status.rawValue, error, Date(), runId.uuidString])
            try db.execute(sql: "UPDATE message SET status = 'failed', error = ?, updatedAt = ? WHERE agentRunId = ? AND status = 'streaming'",
                           arguments: [error ?? (status == .aborted ? "已停止" : "interrupted"), Date(), runId.uuidString])
            if status != .complete {
                try Self.ensureFailureMessage(db, run, error: error ?? (status == .aborted ? "已停止" : "运行失败"))
            }
        }
    }

    static func interruptRunningAgents(_ db: Database) throws {
        let runs = try AgentRunRecord.filter(Column("status") == "running").fetchAll(db)
        try db.execute(sql: "UPDATE agentRun SET status = 'interrupted', error = 'interrupted', updatedAt = ? WHERE status = 'running'", arguments: [Date()])
        for run in runs { try ensureFailureMessage(db, run, error: "interrupted") }
    }

    private static func ensureFailureMessage(_ db: Database, _ run: AgentRunRecord, error: String) throws {
        guard try Message.filter(Column("agentRunId") == run.id.uuidString && Column("status") == "failed").fetchCount(db) == 0 else { return }
        try projectText(db, run, id: run.id.uuidString + ":failure", text: "", status: .failed, error: error)
    }

    /// Explicit retry only. Repair committed results first; never discard or repeat an already committed tool effect.
    /// nil means the final assistant message was already committed; only the terminal run status needed repair.
    public func resumeAgentRun(runId: UUID, timeZone: TimeZone = .current) throws -> PreparedAgentRun? {
        try writer.write { db in
            guard let previous = try AgentRunRecord.fetchOne(db, key: runId.uuidString),
                  [.failed, .aborted, .interrupted].contains(previous.status) else { throw AgentStoreError.cannotResume }
            try Self.requireIdle(db, previous.conversationId)
            let latest = try AgentRunRecord.fetchOne(db, sql: "SELECT * FROM agentRun WHERE conversationId = ? ORDER BY rowid DESC LIMIT 1", arguments: [previous.conversationId.uuidString])
            guard latest?.id == previous.id else { throw AgentStoreError.cannotResume }
            let history = try Self.contextEntries(Self.transcript(db, previous.conversationId))
            let pending = try Self.pendingCalls(history)
            try db.execute(sql: "DELETE FROM message WHERE agentRunId = ? AND agentMessageId = ?",
                           arguments: [previous.id.uuidString, previous.id.uuidString + ":failure"])
            if let last = history.last, pending.isEmpty, (try AgentJSON.object(last.payload))["role"] as? String == "assistant" {
                try db.execute(sql: "UPDATE agentRun SET status = 'complete', error = NULL, updatedAt = ? WHERE id = ?", arguments: [Date(), previous.id.uuidString])
                return nil
            }
            let now = Date()
            let run = AgentRunRecord(id: UUID(), conversationId: previous.conversationId, userMessageId: previous.userMessageId,
                                     status: .running, createdAt: now, updatedAt: now)
            try run.insert(db)
            for (source, call) in pending {
                let execution = try Self.performProposal(db, previous.conversationId, source.id, call, actorId: actorId, timeZone: timeZone)
                try Self.insertTranscript(db, previous.conversationId, id: "recovered:\(source.id):\(call.id)",
                                          runId: run.id, source: source.id, payload: execution.resultJSON)
            }
            let recovered = try Self.contextEntries(Self.transcript(db, previous.conversationId))
            guard let last = recovered.last, ["user", "toolResult"].contains(try AgentJSON.object(last.payload)["role"] as? String ?? "") else {
                throw AgentStoreError.cannotResume
            }
            return PreparedAgentRun(run: run, historyJSON: try Self.historyJSON(db, recovered, inlineFor: previous.userMessageId.uuidString), inputJSON: nil)
        }
    }

    /// Added to the next system context; original tool results remain immutable.
    public func agentProposalContext(conversationId: UUID) throws -> String {
        try writer.read { db in
            let proposals = try Message.filter(Column("conversationId") == conversationId.uuidString && ["proposal", "repayment"].contains(Column("kind")))
                .order(Column("createdAt")).fetchAll(db)
            return proposals.map { "卡片 \($0.id.uuidString)：\($0.proposalState?.rawValue ?? "pending")；\($0.payload ?? "")" }.joined(separator: "\n")
        }
    }

    private static func activeRun(_ db: Database, _ conversationId: UUID, _ id: UUID) throws -> AgentRunRecord {
        guard let run = try AgentRunRecord.fetchOne(db, key: id.uuidString), run.conversationId == conversationId, run.status == .running else {
            throw AgentStoreError.staleRun
        }
        return run
    }

    private static func requireIdle(_ db: Database, _ conversationId: UUID) throws {
        guard try Conversation.fetchOne(db, key: conversationId.uuidString) != nil else { throw AgentStoreError.invalidMessage }
        if try AgentRunRecord.filter(Column("conversationId") == conversationId.uuidString && Column("status") == "running").fetchCount(db) > 0 { throw AgentStoreError.busy }
    }

    private static func transcript(_ db: Database, _ conversationId: UUID) throws -> [AgentTranscriptEntry] {
        let entries = try AgentTranscriptEntry.filter(Column("conversationId") == conversationId.uuidString).order(Column("sequence")).fetchAll(db)
        guard entries.allSatisfy({ $0.formatVersion == 1 }) else { throw AgentStoreError.invalidMessage }
        return entries
    }

    private static func contextEntries(_ entries: [AgentTranscriptEntry]) throws -> [AgentTranscriptEntry] {
        let incompleteIds = Set(try entries.filter { AgentJSON.incomplete(try AgentJSON.object($0.payload)) }.map(\.id))
        return entries.filter { !incompleteIds.contains($0.id) && !incompleteIds.contains($0.sourceMessageId ?? "") }
    }

    private static func historyJSON(_ db: Database, _ entries: [AgentTranscriptEntry], inlineFor inlineId: String?) throws -> String {
        try AgentJSON.encode(entries.map { entry in
            ["id": entry.id, "message": try modelMessage(db, AgentJSON.object(entry.payload), inlineImages: entry.id == inlineId)]
        })
    }

    /// Photos are sent once, with the turn that attached them; later turns see a text stand-in to keep requests small.
    private static func modelMessage(_ db: Database, _ message: [String: Any], inlineImages: Bool) throws -> [String: Any] {
        guard message["role"] as? String == "user", let blocks = message["content"] as? [[String: Any]] else { return message }
        var result = message
        result["content"] = try blocks.map { block -> [String: Any] in
            guard block["type"] as? String == "image", let id = block["imageId"] as? String else { return block }
            guard inlineImages else { return ["type": "text", "text": "（用户发送的照片，已在当时处理）"] }
            guard let data = try Data.fetchOne(db, sql: "SELECT data FROM messageImage WHERE id = ?", arguments: [id]) else {
                throw AgentStoreError.invalidMessage
            }
            return ["type": "image", "mimeType": block["mimeType"] ?? "image/jpeg", "data": data.base64EncodedString()]
        }
        return result
    }

    private static func insertTranscript(_ db: Database, _ conversationId: UUID, id: String, runId: UUID?, source: String? = nil, payload: String) throws {
        let sequence = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM agentTranscript WHERE conversationId = ?", arguments: [conversationId.uuidString])!
        try AgentTranscriptEntry(conversationId: conversationId, id: id, sequence: sequence, runId: runId, sourceMessageId: source, payload: payload).insert(db)
    }

    private static func pendingCalls(_ entries: [AgentTranscriptEntry]) throws -> [(AgentTranscriptEntry, AgentJSON.Call)] {
        var pending: [(AgentTranscriptEntry, AgentJSON.Call)] = []
        for entry in entries {
            let message = try AgentJSON.object(entry.payload)
            if message["role"] as? String == "toolResult" {
                guard let first = pending.first, entry.sourceMessageId == first.0.id,
                      message["toolCallId"] as? String == first.1.id else { throw AgentStoreError.invalidMessage }
                pending.removeFirst()
            } else {
                guard pending.isEmpty else { throw AgentStoreError.invalidMessage }
                pending = try AgentJSON.calls(entry.payload).map { (entry, $0) }
            }
        }
        return pending
    }

    private static func execution(_ db: Database, _ conversationId: UUID, _ source: String, _ callId: String) throws -> AgentToolExecution? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM agentToolExecution WHERE conversationId = ? AND assistantMessageId = ? AND toolCallId = ?", arguments: [conversationId.uuidString, source, callId]) else { return nil }
        let result: String = row["result"]
        let object = try AgentJSON.object(result)
        let isError = object["isError"] as? Bool == true
        return AgentToolExecution(resultJSON: result, proposalId: (row["proposalId"] as String?).flatMap(UUID.init(uuidString:)), isError: isError,
                                  errorMessage: isError ? AgentJSON.text(object) : nil)
    }

    private static func saveExecution(_ db: Database, _ conversationId: UUID, _ source: String, _ call: AgentJSON.Call, result: String, proposalId: UUID?) throws {
        try db.execute(sql: "INSERT INTO agentToolExecution (conversationId, assistantMessageId, toolCallId, name, arguments, result, proposalId, completedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                       arguments: [conversationId.uuidString, source, call.id, call.name, call.arguments, result, proposalId?.uuidString, Date()])
    }

    public static let cardTools: Set<String> = ["propose_expense", "propose_repayment"]

    private static func performProposal(_ db: Database, _ conversationId: UUID, _ source: String, _ call: AgentJSON.Call, actorId: UUID, timeZone: TimeZone) throws -> AgentToolExecution {
        if let existing = try execution(db, conversationId, source, call.id) { return existing }
        guard let next = try pendingCalls(contextEntries(transcript(db, conversationId))).first,
              next.0.id == source, next.1.id == call.id else { throw AgentStoreError.invalidMessage }
        guard let conversation = try Conversation.fetchOne(db, key: conversationId.uuidString) else { throw AgentStoreError.invalidMessage }
        let now = Date()
        var proposalId: UUID?
        var errorText: String?
        let kind: MessageKind = call.name == "propose_repayment" ? .repayment : .proposal
        // Only domain failures become durable tool errors. SQL/storage failures must abort the entire transaction.
        do {
            guard cardTools.contains(call.name) else { throw ProposalError.malformed }
            let participants = try Participant.filter(Column("ledgerId") == conversation.ledgerId.uuidString && Column("deletedAt") == nil).fetchAll(db)
            if kind == .repayment {
                _ = try RepaymentProposal.decode(call.arguments).resolve(participants: participants.map { ($0.id, $0.name) })
            } else {
                let draft = try ExpenseProposal.decode(call.arguments).draft(ledgerId: conversation.ledgerId, participants: participants.map { ($0.id, $0.name) }, now: now, timeZone: timeZone)
                _ = try ExpenseBuilder.build(draft, ledgerParticipantIds: Set(participants.map(\.id)), actorId: actorId, now: now)
            }
            proposalId = UUID()
        } catch let error as ProposalError { errorText = error.localizedDescription }
        catch let error as DomainError { errorText = String(describing: error) }
        let text: String
        if let proposalId {
            let proposal = Message(id: proposalId, conversationId: conversationId, role: .assistant, text: "", status: .complete,
                                   createdAt: now, updatedAt: now, kind: kind, payload: call.arguments, proposalState: .pending)
            try proposal.insert(db)
            text = try AgentJSON.encode(["proposalId": proposalId.uuidString, "status": "pending_confirmation"])
        } else { text = errorText ?? "工具参数无效" }
        let result = try AgentJSON.encode([
            "role": "toolResult", "toolCallId": call.id, "toolName": call.name,
            "content": [["type": "text", "text": text]], "details": [:] as [String: String],
            "isError": errorText != nil, "timestamp": now.timeIntervalSince1970 * 1000,
        ])
        try saveExecution(db, conversationId, source, call, result: result, proposalId: proposalId)
        return AgentToolExecution(resultJSON: result, proposalId: proposalId, isError: errorText != nil, errorMessage: errorText)
    }

    private static func projectText(_ db: Database, _ run: AgentRunRecord, id: String, text: String, status: MessageStatus, error: String? = nil) throws {
        let existing = try Message.filter(Column("conversationId") == run.conversationId.uuidString && Column("agentMessageId") == id).fetchOne(db)
        if text.isEmpty && status == .complete {
            if let existing { try existing.delete(db) }
            return
        }
        let now = Date()
        let message = Message(id: existing?.id ?? UUID(), conversationId: run.conversationId, role: .assistant, text: text,
                              status: status, error: error, createdAt: existing?.createdAt ?? now, updatedAt: now,
                              agentRunId: run.id, agentMessageId: id)
        try message.save(db)
    }

    private static func touchConversation(_ db: Database, _ id: UUID) throws {
        try db.execute(sql: "UPDATE conversation SET updatedAt = ? WHERE id = ?", arguments: [Date(), id.uuidString])
    }

    private static func importAgentHistory(_ db: Database, _ conversationId: UUID) throws {
        let version = try Int.fetchOne(db, sql: "SELECT agentHistoryVersion FROM conversation WHERE id = ?", arguments: [conversationId.uuidString])
        guard version == 0 || version == 1 else { throw AgentStoreError.invalidMessage }
        if version == 1 { return }
        let messages = try Message.filter(Column("conversationId") == conversationId.uuidString && Column("status") == "complete")
            .order(Column("createdAt"), Column("id")).fetchAll(db)
        for message in messages {
            let text = message.kind != .text
                ? "（历史记账卡片：\(message.payload ?? "")；状态：\(message.proposalState?.rawValue ?? "pending")）" : message.text
            var payload: [String: Any] = ["role": message.role.rawValue, "content": text, "timestamp": message.createdAt.timeIntervalSince1970 * 1000]
            if message.role == .assistant {
                payload["content"] = [["type": "text", "text": text]]
                payload["api"] = "openai-completions"; payload["provider"] = "legacy"; payload["model"] = "legacy"
                payload["stopReason"] = "stop"
                payload["usage"] = ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0,
                                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]
            }
            try insertTranscript(db, conversationId, id: message.id.uuidString, runId: nil, payload: AgentJSON.encode(payload))
            try db.execute(sql: "UPDATE message SET agentMessageId = ? WHERE id = ?", arguments: [message.id.uuidString, message.id.uuidString])
        }
        try db.execute(sql: "UPDATE conversation SET agentHistoryVersion = 1 WHERE id = ?", arguments: [conversationId.uuidString])
    }
}

private enum AgentJSON {
    struct Call { let id: String; let name: String; let arguments: String }
    static func encode(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
    static func object(_ json: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw AgentStoreError.invalidMessage }
        return value
    }
    static func text(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        return (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }
    static func identity(_ json: String) throws -> String {
        var value = try object(json)
        if let blocks = value["content"] as? [[String: Any]] {
            value["content"] = blocks.map { $0["type"] as? String == "image" ? ["type": "image", "mimeType": $0["mimeType"] ?? ""] : $0 }
        }
        return try encode(value)
    }
    static func incomplete(_ object: [String: Any]) -> Bool {
        object["role"] as? String == "assistant" && ["error", "aborted", "length"].contains(object["stopReason"] as? String ?? "")
    }
    static func message(_ json: String) throws -> [String: Any] {
        let value = try object(json)
        guard let role = value["role"] as? String, ["user", "assistant", "toolResult"].contains(role), value["timestamp"] is NSNumber else { throw AgentStoreError.invalidMessage }
        if role == "assistant" {
            guard value["content"] is [[String: Any]], value["model"] is String, value["provider"] is String, value["api"] is String,
                  ["stop", "toolUse", "length", "error", "aborted"].contains(value["stopReason"] as? String ?? "") else { throw AgentStoreError.invalidMessage }
            _ = try calls(json)
        } else if role == "toolResult" {
            guard value["toolCallId"] is String, value["toolName"] is String, value["content"] is [[String: Any]], value["isError"] is Bool else { throw AgentStoreError.invalidMessage }
        } else if !(value["content"] is String) && !(value["content"] is [[String: Any]]) { throw AgentStoreError.invalidMessage }
        return value
    }
    static func calls(_ json: String) throws -> [Call] {
        let value = try object(json)
        guard value["role"] as? String == "assistant" else { return [] }
        let calls = try (value["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "toolCall" }.map { block in
            guard let id = block["id"] as? String, !id.isEmpty, let name = block["name"] as? String, !name.isEmpty,
                  let arguments = block["arguments"] as? [String: Any] else { throw AgentStoreError.invalidMessage }
            return Call(id: id, name: name, arguments: try encode(arguments))
        }
        guard Set(calls.map(\.id)).count == calls.count else { throw AgentStoreError.invalidMessage }
        return calls
    }
    static func resultBody(_ object: [String: Any]) throws -> String {
        try encode(["content": object["content"] ?? [], "details": object["details"] ?? [:], "isError": object["isError"] ?? false])
    }
}
