import Foundation
import GRDB
import LedgerDomain

extension LedgerStore {
    @discardableResult
    public func recordTransfer(ledgerId: UUID, from: UUID, to: UUID, amount: Money, occurredAt: Date = Date(), note: String? = nil) throws -> Transfer {
        guard amount.minor > 0 else { throw DomainError.invalidAmount }
        guard from != to else { throw DomainError.sameParticipant }
        return try writer.write { db in
            let members = Set(try Participant.filter(Column("ledgerId") == ledgerId.uuidString && Column("deletedAt") == nil).fetchAll(db).map(\.id))
            for id in [from, to] where !members.contains(id) { throw DomainError.participantNotInLedger(id) }
            let now = Date()
            let transfer = Transfer(id: UUID(), ledgerId: ledgerId, fromParticipantId: from, toParticipantId: to,
                                    currency: amount.currency, amountMinor: amount.minor,
                                    settlesCurrency: amount.currency, settlesMinor: amount.minor,
                                    occurredAt: occurredAt, kind: .settlement, note: note,
                                    createdAt: now, updatedAt: now, version: 1, createdBy: actorId, updatedBy: actorId)
            try transfer.insert(db)
            let tx = JournalTx(id: UUID(), ledgerId: ledgerId, sourceType: .transfer, sourceId: transfer.id, occurredAt: occurredAt)
            try tx.insert(db)
            try JournalEntry(id: UUID(), txId: tx.id, participantId: from, currency: amount.currency, amountMinor: amount.minor).insert(db)
            try JournalEntry(id: UUID(), txId: tx.id, participantId: to, currency: amount.currency, amountMinor: -amount.minor).insert(db)
            return transfer
        }
    }

    public func deleteTransfer(id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE transfer SET deletedAt = ?, updatedAt = ?, updatedBy = ?, version = version + 1 WHERE id = ? AND deletedAt IS NULL",
                           arguments: [Date(), Date(), actorId.uuidString, id.uuidString])
            try db.execute(sql: "DELETE FROM journalTx WHERE sourceType = 'transfer' AND sourceId = ?", arguments: [id.uuidString])
        }
    }
}
