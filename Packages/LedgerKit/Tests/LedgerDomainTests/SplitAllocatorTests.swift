import Foundation
import LedgerDomain
import Testing

private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

@Test func equalSplitDistributesRemainderByIdAscending() {
    let result = SplitAllocator.allocate(amount: 100, weights: [c: 1, a: 1, b: 1])
    #expect(result == [a: 34, b: 33, c: 33])
}

@Test func weightedSplitHonoursWeights() {
    let result = SplitAllocator.allocate(amount: 300, weights: [a: 2, b: 1])
    #expect(result == [a: 200, b: 100])
}

@Test func zeroWeightOwesNothing() {
    let result = SplitAllocator.allocate(amount: 100, weights: [a: 1, b: 0])
    #expect(result == [a: 100, b: 0])
}

@Test func negativeAmountSplitsAbsoluteThenNegates() {
    let result = SplitAllocator.allocate(amount: -100, weights: [a: 1, b: 1, c: 1])
    #expect(result == [a: -34, b: -33, c: -33])
}

@Test func expenseAllocationCoversAllRules() throws {
    let expenseId = UUID()
    let pasta = UUID(), drink = UUID(), chicken = UUID(), tax = UUID()
    let lines = [
        ExpenseLine(id: pasta, expenseId: expenseId, kind: .item, name: "pasta", quantity: 1, amountMinor: 1200, splitRule: .weighted, sortOrder: 0),
        ExpenseLine(id: drink, expenseId: expenseId, kind: .item, name: "drink", quantity: 1, amountMinor: 400, splitRule: .exact, sortOrder: 1),
        ExpenseLine(id: chicken, expenseId: expenseId, kind: .item, name: "chicken", quantity: 1, amountMinor: 300, splitRule: .weighted, sortOrder: 2),
        ExpenseLine(id: tax, expenseId: expenseId, kind: .tax, name: "tax", quantity: 1, amountMinor: 190, splitRule: .proportional, sortOrder: 3),
    ]
    let consumers = [
        LineConsumer(lineId: pasta, participantId: b),
        LineConsumer(lineId: drink, participantId: a, exactMinor: 400),
        LineConsumer(lineId: chicken, participantId: a),
        LineConsumer(lineId: chicken, participantId: b),
        LineConsumer(lineId: chicken, participantId: c),
    ]
    let result = try SplitAllocator.allocate(lines: lines, consumers: consumers)
    let owed = Dictionary(grouping: result, by: \.participantId).mapValues { $0.reduce(0) { $0 + $1.owedMinor } }
    #expect(result.reduce(0) { $0 + $1.owedMinor } == 2090)
    #expect(owed[a] ?? .min == 400 + 100 + 50)
    #expect(owed[b] ?? .min == 1200 + 100 + 130)
    #expect(owed[c] ?? .min == 100 + 10)
}

@Test func exactMustSumToLineAmount() {
    let expenseId = UUID(), line = UUID()
    let lines = [ExpenseLine(id: line, expenseId: expenseId, kind: .item, name: "x", quantity: 1, amountMinor: 100, splitRule: .exact, sortOrder: 0)]
    let consumers = [LineConsumer(lineId: line, participantId: a, exactMinor: 60), LineConsumer(lineId: line, participantId: b, exactMinor: 30)]
    #expect(throws: DomainError.exactSharesMismatch(lineId: line)) {
        try SplitAllocator.allocate(lines: lines, consumers: consumers)
    }
}

@Test func weightedLineNeedsPositiveWeight() {
    let expenseId = UUID(), line = UUID()
    let lines = [ExpenseLine(id: line, expenseId: expenseId, kind: .item, name: "x", quantity: 1, amountMinor: 100, splitRule: .weighted, sortOrder: 0)]
    #expect(throws: DomainError.noConsumers(lineId: line)) {
        try SplitAllocator.allocate(lines: lines, consumers: [LineConsumer(lineId: line, participantId: a, weight: 0)])
    }
}
