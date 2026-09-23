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
    for amount in ["12oops", "9223372036854775808", "18446744073709551617"] {
        #expect(throws: ProposalError.invalidAmount(amount)) {
            try draft("{\"merchant\":\"x\",\"amount\":\"\(amount)\",\"currency\":\"JPY\",\"payer\":\"innei\"}")
        }
    }
    let cents = try draft(#"{"merchant":"x","amount":"12.50","currency":"USD","payer":"neko","consumers":["neko","neko"]}"#)
    #expect(cents.totalMinor == 1250)
    #expect(cents.lines[0].consumers.count == 1)
}

@Test func itemizedProposalKeepsOneBillAndChecksItsTotal() throws {
    let json = #"{"merchant":"麵屋優光","amount":"2580","currency":"JPY","payer":"innei","items":[{"name":"鶏白湯らーめん","amount":"1250","consumers":["innei"]},{"name":"淡竹","amount":"900","consumers":["whitewater"]},{"name":"饺子","amount":"430","consumers":["innei","whitewater"]}]}"#
    let draft = try ExpenseProposal.decode(json).draft(ledgerId: ledger, participants: members)
    #expect(draft.totalMinor == 2580)
    #expect(draft.payments.count == 1)
    #expect(draft.payments[0].amountMinor == 2580)
    #expect(draft.lines.map(\.name) == ["鶏白湯らーめん", "淡竹", "饺子"])
    #expect(draft.lines.map(\.amountMinor) == [1250, 900, 430])
    #expect(draft.lines.map { $0.consumers.map(\.participantId) } == [[me], [white], [me, white]])
    let built = try ExpenseBuilder.build(draft, ledgerParticipantIds: Set(members.map(\.id)), actorId: me)
    let balances = Dictionary(grouping: built.entries, by: \.participantId).mapValues { $0.reduce(0) { $0 + $1.amountMinor } }
    #expect(balances[me] == 1115)
    #expect(balances[white] == -1115)

    let mismatch = json.replacingOccurrences(of: "\"430\"", with: "\"429\"")
    #expect(throws: ProposalError.itemTotalMismatch) {
        try ExpenseProposal.decode(mismatch).draft(ledgerId: ledger, participants: members)
    }
    let empty = #"{"merchant":"x","amount":"1","currency":"JPY","payer":"innei","items":[]}"#
    #expect(throws: ProposalError.emptyItems) {
        try ExpenseProposal.decode(empty).draft(ledgerId: ledger, participants: members)
    }
}

@Test func proposalKeepsStayRangeAndOriginalPrice() throws {
    let stay = try ExpenseProposal.decode(#"{"merchant":"Airbnb","amount":"346.97","currency":"USD","payer":"whitewater","occurred_at":"2026-09-15","ends_at":"2026-09-18"}"#)
        .draft(ledgerId: ledger, participants: members, timeZone: tokyo)
    let nights = Calendar(identifier: .gregorian).dateComponents([.day], from: stay.occurredAt, to: try #require(stay.endsAt)).day
    #expect(nights == 3)

    let onimaru = try ExpenseProposal.decode(#"{"merchant":"おにまる","amount":"17.03","currency":"CNY","payer":"innei","consumers":["innei"],"original_amount":"399","original_currency":"jpy"}"#)
        .draft(ledgerId: ledger, participants: members)
    #expect(onimaru.original == Money(minor: 399, currency: "JPY"))

    #expect(throws: ProposalError.invalidDate("2026-09-14")) {
        try ExpenseProposal.decode(#"{"merchant":"x","amount":"1","currency":"USD","payer":"innei","occurred_at":"2026-09-15","ends_at":"2026-09-14"}"#)
            .draft(ledgerId: ledger, participants: members, timeZone: tokyo)
    }
    #expect(throws: ProposalError.invalidCurrency("CNY")) {
        try ExpenseProposal.decode(#"{"merchant":"x","amount":"1","currency":"CNY","payer":"innei","original_amount":"1","original_currency":"CNY"}"#)
            .draft(ledgerId: ledger, participants: members)
    }
}

@Test func proposalSplitsByExactShares() throws {
    let draft = try ExpenseProposal.decode(#"{"merchant":"晚餐","amount":"2000","currency":"JPY","payer":"innei","shares":[{"member":"neko","amount":"1200"},{"member":"innei","amount":"800"}]}"#)
        .draft(ledgerId: ledger, participants: members)
    #expect(draft.lines[0].splitRule == .exact)
    #expect(draft.lines[0].consumers.map(\.exactMinor) == [1200, 800])
    #expect(throws: ProposalError.shareTotalMismatch) {
        try ExpenseProposal.decode(#"{"merchant":"x","amount":"2000","currency":"JPY","payer":"innei","shares":[{"member":"neko","amount":"1000"}]}"#)
            .draft(ledgerId: ledger, participants: members)
    }
}
