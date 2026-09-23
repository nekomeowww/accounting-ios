import Foundation

public struct PlaceHint: Hashable, Sendable, Codable {
    public var name: String
    public var branch: String?
    public var address: String?
    public var phone: String?
    public var area: String?

    public init(name: String, branch: String? = nil, address: String? = nil, phone: String? = nil, area: String? = nil) {
        self.name = name
        self.branch = branch
        self.address = address
        self.phone = phone
        self.area = area
    }
}

public struct ExpenseProposal: Hashable, Sendable, Codable {
    public var merchant: String
    public var amount: String
    public var currency: String
    public var payer: String
    public var consumers: [String]?
    public var occurredAt: String?
    public var category: String?
    public var note: String?
    public var place: PlaceHint?

    enum CodingKeys: String, CodingKey {
        case merchant, amount, currency, payer, consumers, category, note, place
        case occurredAt = "occurred_at"
    }

    public static let inputSchema = """
        {"type":"object","additionalProperties":false,"required":["merchant","amount","currency","payer"],"properties":{
        "merchant":{"type":"string","description":"商户或事项名称"},
        "amount":{"type":"string","description":"总金额，原币主单位的十进制字符串，如 \\"9700\\" 或 \\"12.50\\""},
        "currency":{"type":"string","description":"ISO 4217 币种代码，如 JPY、CNY、USD"},
        "payer":{"type":"string","description":"付款的成员名，必须是账本成员之一"},
        "consumers":{"type":"array","items":{"type":"string"},"description":"平摊这笔钱的成员名；省略表示全员。个人消费或请客只写承担者本人"},
        "occurred_at":{"type":"string","description":"消费时间 yyyy-MM-ddTHH:mm（本地时间），省略表示现在"},
        "category":{"type":"string","description":"分类，如 餐饮、交通、住宿、门票、购物"},
        "note":{"type":"string","description":"备注"},
        "place":{"type":"object","additionalProperties":false,"required":["name"],"description":"消费地点线索","properties":{
        "name":{"type":"string","description":"店名，不含分店"},
        "branch":{"type":"string","description":"分店名，如「京都四条河原町店」「ラスカ熱海店」，只能从用户原话或小票里抠，不要编造"},
        "address":{"type":"string","description":"小票或原话中的地址，含 〒，只能从用户原话或小票里抠，不要编造"},
        "phone":{"type":"string","description":"电话，只能从用户原话或小票里抠，不要编造"},
        "area":{"type":"string","description":"城市或街区，如「京都 下京区」，可以根据住宿和当天其他消费推断，但要写在 area 里，不要冒充分店名"}}}}}
        """

    public static func decode(_ json: String) throws -> ExpenseProposal {
        do {
            return try JSONDecoder().decode(ExpenseProposal.self, from: Data(json.utf8))
        } catch {
            throw ProposalError.malformed
        }
    }

    public func draft(ledgerId: UUID, participants: [(id: UUID, name: String)], now: Date = Date(), timeZone: TimeZone = .current) throws -> ExpenseDraft {
        func resolve(_ name: String) throws -> UUID {
            let key = name.trimmingCharacters(in: .whitespaces)
            guard let match = participants.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) else {
                throw ProposalError.unknownMember(key)
            }
            return match.id
        }
        let code = currency.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 3 else { throw ProposalError.invalidCurrency(currency) }
        guard let major = Decimal(string: amount.trimmingCharacters(in: .whitespaces), locale: Locale(identifier: "en_US_POSIX")) else {
            throw ProposalError.invalidAmount(amount)
        }
        let scaled = major * pow(10, Currency.exponent(for: code))
        var rounded = Decimal()
        var copy = scaled
        NSDecimalRound(&rounded, &copy, 0, .plain)
        guard rounded == scaled, rounded > 0 else { throw ProposalError.invalidAmount(amount) }
        let minor = NSDecimalNumber(decimal: rounded).int64Value

        let payerId = try resolve(payer)
        var consumerIds: [UUID] = []
        for id in try (consumers?.isEmpty == false ? consumers! : participants.map(\.name)).map(resolve) where !consumerIds.contains(id) {
            consumerIds.append(id)
        }
        let occurred = try occurredAt.map { raw -> Date in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = raw.count > 16 ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd'T'HH:mm"
            guard let date = formatter.date(from: raw) else { throw ProposalError.invalidDate(raw) }
            return date
        } ?? now

        return ExpenseDraft(
            ledgerId: ledgerId, merchant: merchant, note: note, category: category,
            occurredAt: occurred, timeZone: timeZone.identifier, currency: code, source: .agent,
            lines: [LineDraft(name: merchant, amountMinor: minor, consumers: consumerIds.map { ConsumerDraft($0) })],
            payments: [PaymentDraft(payerId, amountMinor: minor)]
        )
    }
}

public enum ProposalError: Error, Equatable, Sendable, LocalizedError {
    case malformed
    case unknownMember(String)
    case invalidAmount(String)
    case invalidCurrency(String)
    case invalidDate(String)
    case notPending

    public var errorDescription: String? {
        switch self {
        case .malformed: "卡片内容无法解析"
        case .unknownMember(let name): "找不到成员「\(name)」"
        case .invalidAmount(let amount): "金额无效：\(amount)"
        case .invalidCurrency(let code): "币种无效：\(code)"
        case .invalidDate(let raw): "时间无效：\(raw)"
        case .notPending: "这张卡片已处理"
        }
    }
}
