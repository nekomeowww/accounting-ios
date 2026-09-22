import Foundation

public struct Money: Hashable, Sendable, Codable {
    public var minor: Int64
    public var currency: String

    public init(minor: Int64, currency: String) {
        self.minor = minor
        self.currency = currency
    }

    public var exponent: Int { Currency.exponent(for: currency) }

    public var decimal: Decimal {
        Decimal(minor) / pow(10, exponent)
    }
}

public enum Currency {
    private static let exponents: [String: Int] = [
        "JPY": 0, "KRW": 0, "VND": 0, "CLP": 0, "ISK": 0,
        "BHD": 3, "KWD": 3, "OMR": 3, "JOD": 3, "TND": 3,
    ]

    public static func exponent(for code: String) -> Int {
        exponents[code.uppercased()] ?? 2
    }
}

extension Money {
    public var formatted: String {
        decimal.formatted(.currency(code: currency).precision(.fractionLength(exponent)))
    }
}
