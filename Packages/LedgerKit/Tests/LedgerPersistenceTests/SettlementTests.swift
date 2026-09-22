import Foundation
import GRDB
import LedgerDomain
import LedgerPersistence
import Testing

@Test func tripsSpreadsheetGolden() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, innei) = try store.createLedger(name: "日本旅行 2026.09", currency: "JPY", settlementCurrency: "CNY", myName: "innei")
    let whitewater = try store.addParticipant(ledgerId: ledger.id, name: "whitewater")
    let neko = try store.addParticipant(ledgerId: ledger.id, name: "neko")
    let rizumu = try store.addParticipant(ledgerId: ledger.id, name: "rizumu")
    let four = [whitewater, innei, neko, rizumu]
    let two = [whitewater, innei]

    let shared: [(Participant, Int64, String, [Participant])] = [
        (whitewater, 34697, "USD", four), (whitewater, 37950, "JPY", four), (whitewater, 71046, "USD", four),
        (innei, 269800, "CNY", two), (innei, 187600, "CNY", two), (whitewater, 52523, "USD", four),
        (whitewater, 86603, "USD", four), (innei, 5460, "JPY", two), (innei, 5600, "JPY", four),
        (neko, 5200, "JPY", four), (innei, 1800, "JPY", four), (whitewater, 3135, "JPY", two),
        (whitewater, 9700, "JPY", four), (innei, 1950, "JPY", two), (neko, 49960, "JPY", four),
        (neko, 18400, "JPY", four),
    ]
    let personal: [(Participant, Int64, String, [Participant])] = [
        (innei, 1204, "JPY", [innei]), (innei, 1703, "CNY", [innei]), (innei, 1100, "JPY", [innei]),
    ]
    for (payer, amount, currency, consumers) in shared + personal {
        try store.createExpense(ExpenseDraft(
            ledgerId: ledger.id, merchant: "x", occurredAt: Date(), currency: currency,
            lines: [LineDraft(name: "x", amountMinor: amount, consumers: consumers.map { ConsumerDraft($0.id) })],
            payments: [PaymentDraft(payer.id, amountMinor: amount)]
        ))
    }

    let before = try store.writer.read { try LedgerStore.fetchSettlement($0, ledgerId: ledger.id) }
    #expect(before.missingRates == ["JPY", "USD"])

    try store.setRates(ledgerId: ledger.id, ["USD": Decimal(string: "6.71")!, "JPY": Decimal(string: "0.043")!], source: .manual)
    let settlement = try store.writer.read { try LedgerStore.fetchSettlement($0, ledgerId: ledger.id) }
    #expect(settlement.currency == "CNY")
    #expect(settlement.missingRates.isEmpty)

    let expected: [UUID: Int64] = [whitewater.id: 1_061_051, innei.id: -279_312, neko.id: -232_715, rizumu.id: -549_023]
    let net = Dictionary(uniqueKeysWithValues: settlement.rows.map { ($0.participantId, $0.net.minor) })
    for (id, cents) in expected {
        // Shares are rounded to 1 yen / 1 US cent before conversion, while the spreadsheet divides converted totals exactly.
        #expect(abs(net[id]! - cents) < 100)
    }
    #expect(abs(settlement.rows.reduce(0) { $0 + $1.net.minor }) <= settlement.rows.count)
}

@Test func changingSettlementCurrencyClearsRates() throws {
    let store = try LedgerStore.inMemory()
    let (ledger, _) = try store.createLedger(name: "L", currency: "JPY", settlementCurrency: "CNY", myName: "me")
    try store.setRates(ledgerId: ledger.id, ["JPY": Decimal(string: "0.043")!], source: .fetched, asOf: "2026-09-22")
    let stored = try store.writer.read { try LedgerStore.fetchRates($0, ledgerId: ledger.id) }
    #expect(stored.map(\.rate) == [Decimal(string: "0.043")!])
    #expect(stored.first?.asOf == "2026-09-22")

    try store.setSettlementCurrency(ledgerId: ledger.id, currency: "USD")
    let after = try store.writer.read { db in (try Ledger.fetchOne(db, key: ledger.id.uuidString), try LedgerStore.fetchRates(db, ledgerId: ledger.id)) }
    #expect(after.0?.settlementCurrency == "USD")
    #expect(after.1.isEmpty)
}
