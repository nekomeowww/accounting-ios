import Foundation

public struct RepaymentProposal: Hashable, Sendable, Codable {
    public var from: String
    public var to: String
    public var amount: String
    public var currency: String
    public var note: String?

    public static let inputSchema = """
        {"type":"object","additionalProperties":false,"required":["from","to","amount","currency"],"properties":{
        "from":{"type":"string","description":"给钱（还款）的成员名"},
        "to":{"type":"string","description":"收钱的成员名"},
        "amount":{"type":"string","description":"金额，主单位十进制字符串"},
        "currency":{"type":"string","description":"ISO 4217 币种代码，通常是账本结算币种"},
        "note":{"type":"string","description":"备注，如 微信转账"}}}
        """

    public struct Resolved: Hashable, Sendable {
        public var from: UUID
        public var to: UUID
        public var amount: Money
        public var note: String?
    }

    public static func decode(_ json: String) throws -> RepaymentProposal {
        do { return try JSONDecoder().decode(RepaymentProposal.self, from: Data(json.utf8)) } catch { throw ProposalError.malformed }
    }

    public func resolve(participants: [(id: UUID, name: String)]) throws -> Resolved {
        func member(_ name: String) throws -> UUID {
            let key = name.trimmingCharacters(in: .whitespaces)
            guard let match = participants.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) else { throw ProposalError.unknownMember(key) }
            return match.id
        }
        let code = currency.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 3 else { throw ProposalError.invalidCurrency(currency) }
        guard let money = Money(parsing: amount, currency: code) else { throw ProposalError.invalidAmount(amount) }
        let (fromId, toId) = (try member(from), try member(to))
        guard fromId != toId else { throw ProposalError.samePerson }
        return Resolved(from: fromId, to: toId, amount: money, note: note)
    }
}
