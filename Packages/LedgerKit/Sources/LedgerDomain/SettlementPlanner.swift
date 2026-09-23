import Foundation

public struct PlannedTransfer: Hashable, Sendable {
    public var from: UUID
    public var to: UUID
    public var minor: Int64

    public init(from: UUID, to: UUID, minor: Int64) {
        self.from = from
        self.to = to
        self.minor = minor
    }
}

public enum SettlementPlanner {
    // ponytail: greedy largest-debtor → largest-creditor, at most n-1 transfers; not the global minimum count for every input.
    public static func plan(_ net: [UUID: Int64]) -> [PlannedTransfer] {
        var debtors = net.filter { $0.value < 0 }.map { ($0.key, -$0.value) }
        var creditors = net.filter { $0.value > 0 }.map { ($0.key, $0.value) }
        var transfers: [PlannedTransfer] = []
        while !debtors.isEmpty, !creditors.isEmpty {
            debtors.sort { ($0.1, $0.0.uuidString) > ($1.1, $1.0.uuidString) }
            creditors.sort { ($0.1, $0.0.uuidString) > ($1.1, $1.0.uuidString) }
            let amount = min(debtors[0].1, creditors[0].1)
            transfers.append(PlannedTransfer(from: debtors[0].0, to: creditors[0].0, minor: amount))
            debtors[0].1 -= amount
            creditors[0].1 -= amount
            debtors.removeAll { $0.1 == 0 }
            creditors.removeAll { $0.1 == 0 }
        }
        return transfers
    }
}
