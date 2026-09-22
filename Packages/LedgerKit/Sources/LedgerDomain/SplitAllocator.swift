import Foundation

public enum DomainError: Error, Equatable, Sendable {
    case noLines
    case noItemLine
    case noConsumers(lineId: UUID)
    case exactSharesMismatch(lineId: UUID)
    case noPayments
    case paymentsMismatch(expected: Int64, actual: Int64)
    case participantNotInLedger(UUID)
    case invalidAmount
}

public struct LineAllocation: Hashable, Sendable {
    public var lineId: UUID
    public var participantId: UUID
    public var owedMinor: Int64
}

public enum SplitAllocator {
    public static func allocate(amount: Int64, weights: [UUID: Int64]) -> [UUID: Int64] {
        let positive = weights.filter { $0.value > 0 }
        let totalWeight = positive.values.reduce(0, +)
        var result = weights.mapValues { _ in Int64(0) }
        guard totalWeight > 0 else { return result }
        let magnitude = abs(amount)
        var remainder = magnitude
        for (id, weight) in positive {
            let share = magnitude * weight / totalWeight
            result[id] = share
            remainder -= share
        }
        for id in positive.keys.sorted(by: { $0.uuidString < $1.uuidString }) where remainder > 0 {
            result[id]! += 1
            remainder -= 1
        }
        return amount < 0 ? result.mapValues { -$0 } : result
    }

    public static func allocate(lines: [ExpenseLine], consumers: [LineConsumer]) throws -> [LineAllocation] {
        guard !lines.isEmpty else { throw DomainError.noLines }
        guard lines.contains(where: { $0.kind == .item }) else { throw DomainError.noItemLine }
        let consumersByLine = Dictionary(grouping: consumers, by: \.lineId)
        var allocations: [LineAllocation] = []
        var itemSubtotals: [UUID: Int64] = [:]

        for line in lines.sorted(by: { $0.sortOrder < $1.sortOrder }) where line.splitRule != .proportional {
            let lineConsumers = consumersByLine[line.id] ?? []
            let shares: [UUID: Int64]
            switch line.splitRule {
            case .weighted:
                let weights = Dictionary(uniqueKeysWithValues: lineConsumers.map { ($0.participantId, $0.weight) })
                guard weights.values.contains(where: { $0 > 0 }) else { throw DomainError.noConsumers(lineId: line.id) }
                shares = allocate(amount: line.amountMinor, weights: weights)
            case .exact:
                let exact = Dictionary(uniqueKeysWithValues: lineConsumers.map { ($0.participantId, $0.exactMinor ?? 0) })
                guard !exact.isEmpty else { throw DomainError.noConsumers(lineId: line.id) }
                guard exact.values.reduce(0, +) == line.amountMinor else { throw DomainError.exactSharesMismatch(lineId: line.id) }
                shares = exact
            case .proportional:
                continue
            }
            for (participantId, owed) in shares {
                allocations.append(LineAllocation(lineId: line.id, participantId: participantId, owedMinor: owed))
                if line.kind == .item { itemSubtotals[participantId, default: 0] += owed }
            }
        }

        for line in lines.sorted(by: { $0.sortOrder < $1.sortOrder }) where line.splitRule == .proportional {
            let shares = allocate(amount: line.amountMinor, weights: itemSubtotals)
            guard line.amountMinor == 0 || shares.values.contains(where: { $0 != 0 }) else { throw DomainError.noConsumers(lineId: line.id) }
            for (participantId, owed) in shares {
                allocations.append(LineAllocation(lineId: line.id, participantId: participantId, owedMinor: owed))
            }
        }
        return allocations
    }
}
