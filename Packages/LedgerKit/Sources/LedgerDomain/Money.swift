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
    public init?(parsing text: String, currency: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let major = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var scaled = major * pow(10, Currency.exponent(for: currency))
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled, rounded > 0, rounded <= Decimal(Int64.max) else { return nil }
        self.init(minor: NSDecimalNumber(decimal: rounded).int64Value, currency: currency)
    }

    public var plainText: String {
        decimal.formatted(.number.precision(.fractionLength(0...exponent)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    public func converted(to target: String, rate: Decimal) -> Money {
        var value = decimal * rate * pow(10, Currency.exponent(for: target))
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return Money(minor: NSDecimalNumber(decimal: rounded).int64Value, currency: target)
    }

    public var formatted: String {
        decimal.formatted(.currency(code: currency).precision(.fractionLength(exponent)))
    }
}
