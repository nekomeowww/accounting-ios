import Foundation
import LedgerDomain
import Testing

@Test func planSettlesEveryoneWithAtMostNMinusOneTransfers() {
    let white = UUID(), innei = UUID(), neko = UUID(), rizumu = UUID()
    let net: [UUID: Int64] = [white: 1_061_051, innei: -279_312, neko: -232_715, rizumu: -549_024]
    let plan = SettlementPlanner.plan(net)
    #expect(plan.count == 3)
    #expect(plan.allSatisfy { $0.to == white && $0.minor > 0 })
    #expect(plan.first == PlannedTransfer(from: rizumu, to: white, minor: 549_024))

    var after = net
    for transfer in plan {
        after[transfer.from]! += transfer.minor
        after[transfer.to]! -= transfer.minor
    }
    #expect(after.values.allSatisfy { $0 == 0 })
}

@Test func planHandlesMultipleCreditorsAndSettledLedgers() {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let plan = SettlementPlanner.plan([a: -700, b: -300, c: 600, d: 400])
    #expect(plan.reduce(0) { $0 + $1.minor } == 1000)
    #expect(plan.count <= 3)
    #expect(SettlementPlanner.plan([a: 0, b: 0]).isEmpty)
    #expect(SettlementPlanner.plan([:]).isEmpty)
}

@Test func planLeavesRoundingResidueUnassigned() {
    let a = UUID(), b = UUID()
    #expect(SettlementPlanner.plan([a: -101, b: 100]) == [PlannedTransfer(from: a, to: b, minor: 100)])
}
