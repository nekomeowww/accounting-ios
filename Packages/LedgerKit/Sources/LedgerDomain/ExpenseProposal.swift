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
    public var shares: [ExpenseProposalShare]?
    public var items: [ExpenseProposalItem]?
    public var occurredAt: String?
    public var endsAt: String?
    public var originalAmount: String?
    public var originalCurrency: String?
    public var category: String?
    public var note: String?
    public var place: PlaceHint?

    enum CodingKeys: String, CodingKey {
        case merchant, amount, currency, payer, consumers, shares, items, category, note, place
        case occurredAt = "occurred_at"
        case endsAt = "ends_at"
        case originalAmount = "original_amount"
        case originalCurrency = "original_currency"
    }

    public static let inputSchema = """
        {"type":"object","additionalProperties":false,"required":["merchant","amount","currency","payer"],"properties":{
        "merchant":{"type":"string","description":"商户或事项名称"},
        "amount":{"type":"string","description":"总金额，原币主单位的十进制字符串，如 \\"9700\\" 或 \\"12.50\\""},
        "currency":{"type":"string","description":"ISO 4217 币种代码，如 JPY、CNY、USD"},
        "payer":{"type":"string","description":"付款的成员名，必须是账本成员之一"},
        "consumers":{"type":"array","items":{"type":"string"},"description":"整笔或未单独指定分摊人的项目由这些成员平摊；省略表示全员"},
        "shares":{"type":"array","minItems":1,"description":"按指定金额分摊（不均分）时填写，每人承担的金额之和必须等于 amount；与 items、consumers 互斥","items":{"type":"object","additionalProperties":false,"required":["member","amount"],"properties":{"member":{"type":"string","description":"成员名"},"amount":{"type":"string","description":"该成员承担的金额，原币主单位的十进制字符串"}}}},
        "items":{"type":"array","minItems":1,"description":"同一张账单的项目明细；逐项目分摊时填写，所有项目金额之和必须等于 amount。省略时按单项目记账","items":{"type":"object","additionalProperties":false,"required":["name","amount"],"properties":{"name":{"type":"string","description":"项目名称"},"amount":{"type":"string","description":"该项目金额，原币主单位的十进制字符串"},"consumers":{"type":"array","items":{"type":"string"},"description":"承担该项目的成员；省略时沿用顶层 consumers，再省略表示全员"}}}},
        "occurred_at":{"type":"string","description":"消费时间 yyyy-MM-ddTHH:mm（本地时间），省略表示现在"},
        "ends_at":{"type":"string","description":"跨天消费（住宿、租车）的结束时间 yyyy-MM-ddTHH:mm，如入住 9/15 退房 9/18；普通消费省略"},
        "original_amount":{"type":"string","description":"实际支付币种与标价币种不同时（如支付宝按人民币扣款、标价日元），填标价金额；amount/currency 填实际支付"},
        "original_currency":{"type":"string","description":"标价币种 ISO 代码，与 original_amount 同时填写"},
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
        func minorUnits(_ text: String, in currencyCode: String? = nil) throws -> Int64 {
            guard let money = Money(parsing: text, currency: currencyCode ?? code) else { throw ProposalError.invalidAmount(text) }
            return money.minor
        }
        let minor = try minorUnits(amount)

        let payerId = try resolve(payer)
        func consumerIds(_ names: [String]?) throws -> [UUID] {
            var ids: [UUID] = []
            for id in try (names?.isEmpty == false ? names! : participants.map(\.name)).map(resolve) where !ids.contains(id) {
                ids.append(id)
            }
            return ids
        }
        let lines: [LineDraft]
        if let items {
            guard !items.isEmpty else { throw ProposalError.emptyItems }
            var total: Int64 = 0
            lines = try items.map { item in
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ProposalError.emptyItemName }
                let itemMinor = try minorUnits(item.amount)
                let (sum, overflow) = total.addingReportingOverflow(itemMinor)
                guard !overflow else { throw ProposalError.invalidAmount(amount) }
                total = sum
                return try LineDraft(name: name, amountMinor: itemMinor,
                                     consumers: consumerIds(item.consumers ?? consumers).map { ConsumerDraft($0) })
            }
            guard total == minor else { throw ProposalError.itemTotalMismatch }
        } else if let shares {
            guard !shares.isEmpty else { throw ProposalError.emptyItems }
            var seen = Set<UUID>()
            let exact = try shares.map { share -> ConsumerDraft in
                let id = try resolve(share.member)
                guard seen.insert(id).inserted else { throw ProposalError.shareTotalMismatch }
                return ConsumerDraft(id, exactMinor: try minorUnits(share.amount))
            }
            guard exact.reduce(Int64(0), { $0 + ($1.exactMinor ?? 0) }) == minor else { throw ProposalError.shareTotalMismatch }
            lines = [LineDraft(name: merchant, amountMinor: minor, splitRule: .exact, consumers: exact)]
        } else {
            lines = [try LineDraft(name: merchant, amountMinor: minor,
                                   consumers: consumerIds(consumers).map { ConsumerDraft($0) })]
        }
        func parseDate(_ raw: String) throws -> Date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = raw.count > 16 ? "yyyy-MM-dd'T'HH:mm:ss" : raw.count > 10 ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
            guard let date = formatter.date(from: raw) else { throw ProposalError.invalidDate(raw) }
            return date
        }
        let occurred = try occurredAt.map(parseDate) ?? now
        let ends = try endsAt.map(parseDate)
        if let ends, ends < occurred { throw ProposalError.invalidDate(endsAt!) }
        var original: Money?
        if let originalAmount {
            let originalCode = (originalCurrency ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            guard originalCode.count == 3, originalCode != code else { throw ProposalError.invalidCurrency(originalCurrency ?? "") }
            original = Money(minor: try minorUnits(originalAmount, in: originalCode), currency: originalCode)
        }

        return ExpenseDraft(
            ledgerId: ledgerId, merchant: merchant, note: note, category: category,
            occurredAt: occurred, endsAt: ends, timeZone: timeZone.identifier, currency: code, original: original, source: .agent,
            lines: lines,
            payments: [PaymentDraft(payerId, amountMinor: minor)]
        )
    }
}

public struct ExpenseProposalShare: Hashable, Sendable, Codable {
    public var member: String
    public var amount: String
}

public struct ExpenseProposalItem: Hashable, Sendable, Codable {
    public var name: String
    public var amount: String
    public var consumers: [String]?
}

public enum ProposalError: Error, Equatable, Sendable, LocalizedError {
    case malformed
    case unknownMember(String)
    case invalidAmount(String)
    case invalidCurrency(String)
    case invalidDate(String)
    case emptyItems
    case emptyItemName
    case itemTotalMismatch
    case shareTotalMismatch
    case notPending

    public var errorDescription: String? {
        switch self {
        case .malformed: "卡片内容无法解析"
        case .unknownMember(let name): "找不到成员「\(name)」"
        case .invalidAmount(let amount): "金额无效：\(amount)"
        case .invalidCurrency(let code): "币种无效：\(code)"
        case .invalidDate(let raw): "时间无效：\(raw)"
        case .emptyItems: "账单项目不能为空"
        case .emptyItemName: "项目名称不能为空"
        case .itemTotalMismatch: "项目金额合计与账单总额不符"
        case .shareTotalMismatch: "每人金额合计与账单总额不符，或成员重复"
        case .notPending: "这张卡片已处理"
        }
    }
}
