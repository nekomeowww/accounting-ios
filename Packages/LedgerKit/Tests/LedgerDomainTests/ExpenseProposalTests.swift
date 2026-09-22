import Foundation
import LedgerDomain
import Testing

private let ledger = UUID()
private let me = UUID(), neko = UUID(), white = UUID()
private let members = [(id: me, name: "innei"), (id: neko, name: "neko"), (id: white, name: "whitewater")]
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

@Test func proposalResolvesMembersAndDefaultsToEveryone() throws {
    let proposal = try ExpenseProposal.decode(#"{"merchant":"麺屋 猪一","amount":"9700","currency":"jpy","payer":"WhiteWater","occurred_at":"2026-09-21T19:00","category":"餐饮"}"#)
    let draft = try proposal.draft(ledgerId: ledger, participants: members, timeZone: tokyo)
    #expect(draft.currency == "JPY")
    #expect(draft.source == .agent)
    #expect(draft.totalMinor == 9700)
    #expect(draft.payments.map(\.participantId) == [white])
    #expect(draft.lines[0].consumers.map(\.participantId) == [me, neko, white])
    #expect(draft.occurredAt == ISO8601DateFormatter().date(from: "2026-09-21T10:00:00Z"))
}

@Test func proposalRejectsBadInput() throws {
    func draft(_ json: String) throws -> ExpenseDraft {
        try ExpenseProposal.decode(json).draft(ledgerId: ledger, participants: members)
    }
    #expect(throws: ProposalError.unknownMember("rizumu")) {
        try draft(#"{"merchant":"x","amount":"10","currency":"CNY","payer":"innei","consumers":["innei","rizumu"]}"#)
    }
    #expect(throws: ProposalError.invalidAmount("12.5")) {
        try draft(#"{"merchant":"x","amount":"12.5","currency":"JPY","payer":"innei"}"#)
    }
    #expect(throws: ProposalError.invalidAmount("-3")) {
        try draft(#"{"merchant":"x","amount":"-3","currency":"CNY","payer":"innei"}"#)
    }
    #expect(throws: ProposalError.malformed) { try draft(#"{"merchant":"x"}"#) }
    let cents = try draft(#"{"merchant":"x","amount":"12.50","currency":"USD","payer":"neko","consumers":["neko","neko"]}"#)
    #expect(cents.totalMinor == 1250)
    #expect(cents.lines[0].consumers.count == 1)
}
