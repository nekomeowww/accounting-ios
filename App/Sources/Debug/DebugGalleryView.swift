#if DEBUG
import GRDB
import LedgerDomain
import LedgerPersistence
import SwiftUI

enum DebugGallery: String, CaseIterable, Identifiable {
    case balance = "gallery-balance"
    case expenseRow = "gallery-expense-row"
    case proposal = "gallery-proposal"
    case chat = "gallery-chat"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balance: "余额卡片"
        case .expenseRow: "消费行"
        case .proposal: "记账卡片"
        case .chat: "聊天气泡"
        }
    }

    var symbol: String {
        switch self {
        case .balance: "yensign.circle"
        case .expenseRow: "list.bullet.rectangle"
        case .proposal: "square.and.pencil"
        case .chat: "bubble.left.and.bubble.right"
        }
    }
}

struct DebugGalleryView: View {
    var gallery: DebugGallery
    var fixtures: DebugFixtures?

    var body: some View {
        if let fixtures {
            List { content(fixtures) }
                .listStyle(.insetGrouped)
        } else {
            ContentUnavailableView("没有账本数据", systemImage: "tray", description: Text("先在调试页「重置示例数据」"))
        }
    }

    @ViewBuilder
    private func content(_ f: DebugFixtures) -> some View {
        switch gallery {
        case .balance:
            Section("正常") { BalanceCardView(settlement: f.settlement, myParticipantId: f.me) }
            Section("缺少汇率") { BalanceCardView(settlement: f.settlement.with { $0.missingRates = ["USD", "HKD"] }, myParticipantId: f.me) }
            Section("我应收") { BalanceCardView(settlement: f.settlement, myParticipantId: f.settlement.rows.max { $0.net.minor < $1.net.minor }?.participantId) }
            Section("全部结清") {
                BalanceCardView(settlement: f.settlement.with { s in s.rows = s.rows.map { row in var row = row; row.net.minor = 0; return row } }, myParticipantId: f.me)
            }
            Section("空账本") { BalanceCardView(settlement: Settlement(currency: "CNY", rows: [], missingRates: []), myParticipantId: nil) }
        case .expenseRow:
            Section("多人 / 个人 / 外币") {
                ForEach(f.rows, id: \.id) { ExpenseRowView(row: $0) }
            }
            if let first = f.rows.first {
                Section("超长商户名") {
                    ExpenseRowView(row: first.with { $0.merchant = "ごちそう焼むすび おにまる 京都四条河原町店 特別限定セット 期間限定" })
                }
                Section("0 人承担") {
                    ExpenseRowView(row: first.with { $0.consumerCount = 0 })
                }
            }
        case .proposal:
            ForEach(DebugFixtures.proposals, id: \.title) { sample in
                Section(sample.title) {
                    ProposalCardView(
                        state: sample.state,
                        preview: ProposalPreview.make(payload: sample.payload(f), ledger: f.ledger, store: AppServices.store),
                        onAccept: {}, onDismiss: {}, onOpen: {}
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
        case .chat:
            Section("用户") {
                UserBubbleView(text: "晚饭 9700 日元，白水付的，四人分")
                UserBubbleView(text: "短")
            }
            Section("失败") {
                FailedMessageView(text: "", error: "HTTP 401: invalid api key", onRetry: {})
                FailedMessageView(text: "已经输出的一部分内容……", error: "已停止", onRetry: {})
            }
        }
    }
}

struct DebugFixtures {
    var ledger: Ledger
    var me: UUID?
    var settlement: Settlement
    var rows: [ActivityRow]
    var names: [String]

    static func load(store: LedgerStore) -> DebugFixtures? {
        try? store.writer.read { db in
            guard let ledger = try Ledger.filter(Column("deletedAt") == nil).order(Column("createdAt")).fetchOne(db) else { return nil }
            let me = try Member.filter(Column("ledgerId") == ledger.id.uuidString && Column("actorId") == store.actorId.uuidString).fetchOne(db)?.participantId
            let activity = try LedgerStore.fetchActivity(db, ledgerId: ledger.id)
            let picks = [
                activity.first { $0.consumerCount > 2 },
                activity.first { $0.consumerCount == 1 },
                activity.first { $0.currency != ledger.defaultCurrency },
            ].compactMap { $0 }
            let names = try Participant.filter(Column("ledgerId") == ledger.id.uuidString).order(Column("createdAt")).fetchAll(db).map(\.name)
            return DebugFixtures(ledger: ledger, me: me, settlement: try LedgerStore.fetchSettlement(db, ledgerId: ledger.id), rows: picks, names: names)
        }
    }

    struct ProposalSample: Sendable {
        var title: String
        var state: ProposalState
        var payload: @Sendable (DebugFixtures) -> String
    }

    static let proposals: [ProposalSample] = [
        ProposalSample(title: "待确认 · 全员均分", state: .pending) { f in
            #"{"merchant":"焼肉 弘","amount":"12000","currency":"JPY","payer":"\#(f.names.last ?? "")","category":"餐饮","note":"含饮料"}"#
        },
        ProposalSample(title: "待确认 · 个人消费 · 结算币种", state: .pending) { f in
            #"{"merchant":"Lawson","amount":"12.50","currency":"CNY","payer":"\#(f.names.first ?? "")","consumers":["\#(f.names.first ?? "")"]}"#
        },
        ProposalSample(title: "已记账", state: .accepted) { f in
            #"{"merchant":"新干线","amount":"49960","currency":"JPY","payer":"\#(f.names.first ?? "")","category":"交通"}"#
        },
        ProposalSample(title: "已取消", state: .dismissed) { f in
            #"{"merchant":"便利店","amount":"338","currency":"JPY","payer":"\#(f.names.first ?? "")"}"#
        },
        ProposalSample(title: "解析失败 · 未知成员", state: .pending) { _ in
            #"{"merchant":"x","amount":"100","currency":"JPY","payer":"ghost"}"#
        },
        ProposalSample(title: "解析失败 · 金额精度", state: .pending) { f in
            #"{"merchant":"x","amount":"12.5","currency":"JPY","payer":"\#(f.names.first ?? "")"}"#
        },
    ]
}

extension Settlement {
    func with(_ change: (inout Settlement) -> Void) -> Settlement {
        var copy = self
        change(&copy)
        return copy
    }
}

extension ActivityRow {
    func with(_ change: (inout ActivityRow) -> Void) -> ActivityRow {
        var copy = self
        change(&copy)
        return copy
    }
}
#endif
