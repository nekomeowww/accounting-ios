import Foundation
import GRDB
import LedgerDomain
import LedgerPersistence

enum AgentContextBuilder {
    static func systemPrompt(store: LedgerStore, ledger: Ledger) throws -> String {
        let participants = try store.participants(ledgerId: ledger.id)
        let (activity, settlement, rates, me) = try store.writer.read { db in
            (
                try LedgerStore.fetchActivity(db, ledgerId: ledger.id),
                try LedgerStore.fetchSettlement(db, ledgerId: ledger.id),
                try LedgerStore.fetchRates(db, ledgerId: ledger.id),
                try Member.filter(Column("ledgerId") == ledger.id.uuidString && Column("actorId") == store.actorId.uuidString).fetchOne(db)
            )
        }
        let myName = participants.first { $0.id == me?.participantId }?.name
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"

        var lines: [String] = []
        lines.append("你是账本「\(ledger.name)」的记账助手。只根据下面给出的信息回答用户关于这个账本的问题，用简洁的中文。")
        lines.append("用户要记一笔新消费时，调用 propose_expense 生成记账卡片，由用户确认后才写入。卡片出现后不要声称已经记账。")
        lines.append("金额或付款人不清楚时先追问，不要猜；币种没说就用默认币种；不要编造抹零或额外费用。成员名必须用下面列出的名字。")
        if let myName {
            lines.append("正在和你对话的用户是成员「\(myName)」，用户说的「我」指这个成员。")
        }
        lines.append("你目前不能修改、删除或撤销已有的账目；用户要求时明确说明做不到。")
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "yyyy-MM-dd'T'HH:mm"
        lines.append("当前本地时间：\(clock.string(from: Date()))，时区 \(TimeZone.current.identifier)。")
        lines.append("金额一律带币种。余额已按账本汇率折算成结算币种，不要自己另找汇率换算。")
        lines.append("")
        lines.append("成员：" + participants.map(\.name).joined(separator: "、"))
        lines.append("默认币种：\(ledger.defaultCurrency)；结算币种：\(settlement.currency)")
        lines.append("汇率：" + (rates.isEmpty ? "未设置" : rates.map { "1 \($0.currency) = \($0.rate) \(settlement.currency)" }.joined(separator: "；")))
        lines.append("")
        lines.append("各成员净余额，已折算为 \(settlement.currency)（正数为应收，负数为应付）：")
        for row in settlement.rows {
            lines.append("- \(row.participantName): \(row.net.formatted)")
        }
        if !settlement.missingRates.isEmpty {
            lines.append("注意：缺少 \(settlement.missingRates.joined(separator: "、")) 汇率，这些币种的金额未计入上面的余额。")
        }
        lines.append("")
        lines.append("最近消费（最新在前，最多 20 笔）：")
        for row in activity.prefix(20) {
            formatter.timeZone = TimeZone(identifier: row.timeZone) ?? .current
            lines.append("- \(formatter.string(from: row.occurredAt)) \(row.merchant) \(row.total.formatted)，\(row.payerNames) 支付，\(row.consumerCount) 人承担")
        }
        return lines.joined(separator: "\n")
    }
}
