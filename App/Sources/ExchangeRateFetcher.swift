import Foundation

enum ExchangeRateFetcher {
    struct Result {
        var rates: [String: Decimal]
        var asOf: String
    }

    enum FetchError: LocalizedError {
        case unsupportedBase(String)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedBase(let code): "数据源不支持 \(code)，请手动填写汇率"
            case .http(let status): "获取失败（HTTP \(status)）"
            }
        }
    }

    private struct Response: Decodable {
        var date: String
        var rates: [String: Decimal]
    }

    static func fetch(settlement: String, currencies: [String]) async throws -> Result {
        var components = URLComponents(string: "https://api.frankfurter.dev/v1/latest")!
        components.queryItems = [
            URLQueryItem(name: "base", value: settlement),
            URLQueryItem(name: "symbols", value: currencies.joined(separator: ",")),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw FetchError.unsupportedBase(settlement) }
        guard status == 200 else { throw FetchError.http(status) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let inverted = decoded.rates.compactMapValues { quote -> Decimal? in
            guard quote > 0 else { return nil }
            var value = 1 / quote
            var rounded = Decimal()
            NSDecimalRound(&rounded, &value, 8, .plain)
            return rounded
        }
        return Result(rates: inverted, asOf: decoded.date)
    }
}
