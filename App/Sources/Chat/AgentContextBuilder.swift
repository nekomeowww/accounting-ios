import Foundation
import LedgerDomain
import LedgerPersistence

enum AgentContextBuilder {
    static func systemPrompt(store: LedgerStore, ledger: Ledger) throws -> String {
        let participants = try store.participants(ledgerId: ledger.id)
        let (activity, balances) = try store.writer.read { db in
            (try LedgerStore.fetchActivity(db, ledgerId: ledger.id), try LedgerStore.fetchBalances(db, ledgerId: ledger.id))
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"

        var lines: [String] = []
        lines.append("你是账本「\(ledger.name)」的记账助手。只根据下面给出的信息回答用户关于这个账本的问题，用简洁的中文。")
        lines.append("你目前没有修改账本的能力；如果用户要求记账、改账或撤销，明确说明现在还不能操作，不要声称已经完成。")
        lines.append("金额一律带币种，不同币种不要相加换算。")
        lines.append("")
        lines.append("成员：" + participants.map(\.name).joined(separator: "、"))
        lines.append("默认币种：\(ledger.defaultCurrency)")
        lines.append("")
        lines.append("各成员净余额（正数为应收，负数为应付）：")
        for row in balances {
            lines.append("- \(row.participantName): \(row.net.formatted)")
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
