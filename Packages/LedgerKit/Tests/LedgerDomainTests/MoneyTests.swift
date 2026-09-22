import Foundation
import LedgerDomain
import Testing

@Test func convertsAcrossExponentsAndRoundsHalfUp() {
    #expect(Money(minor: 37950, currency: "JPY").converted(to: "CNY", rate: Decimal(string: "0.043")!) == Money(minor: 163185, currency: "CNY"))
    #expect(Money(minor: 34697, currency: "USD").converted(to: "CNY", rate: Decimal(string: "6.71")!) == Money(minor: 232817, currency: "CNY"))
    #expect(Money(minor: -1, currency: "JPY").converted(to: "CNY", rate: Decimal(string: "0.045")!) == Money(minor: -5, currency: "CNY"))
    #expect(Money(minor: 100, currency: "CNY").converted(to: "JPY", rate: Decimal(string: "23.459")!) == Money(minor: 23, currency: "JPY"))
}
