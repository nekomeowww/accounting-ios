import GRDB
import LedgerDomain
import LedgerPersistence
import SwiftUI
import UIKit

struct ExpenseDetailView: View {
    var detail: ExpenseDetail?
    var myParticipantId: UUID?
    var onOpenMap: (UUID) -> Void = { _ in }

    var body: some View {
        if let detail {
            content(detail)
        } else {
            ContentUnavailableView("这笔消费已删除", systemImage: "trash")
        }
    }

    private func content(_ detail: ExpenseDetail) -> some View {
        List {
            Section {
                header(detail)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            }
            ExpensePlaceSection(
                expenseId: detail.expense.id,
                ledgerId: detail.expense.ledgerId,
                occurredAt: detail.expense.occurredAt,
                place: detail.place,
                placeQuery: detail.placeQuery,
                onOpenMap: onOpenMap
            )
            Section("付款") {
                ForEach(detail.payments, id: \.self) { payment in
                    AmountRow(title: payment.participantName, subtitle: payment.method.map(Self.methodName), amount: detail.money(payment.amountMinor), settled: nil)
                }
            }
            Section("分摊 · \(detail.shares.count) 人") {
                ForEach(detail.shares, id: \.self) { share in
                    AmountRow(
                        title: share.participantId == myParticipantId ? "\(share.participantName)（你）" : share.participantName,
                        subtitle: nil,
                        amount: detail.money(share.owedMinor),
                        settled: detail.settled(share.owedMinor)
                    )
                }
            }
            if detail.lines.count > 1 {
                Section("明细") {
                    ForEach(detail.lines) { line in
                        AmountRow(title: line.name, subtitle: line.quantity > 1 ? "× \(line.quantity)" : nil, amount: detail.money(line.amountMinor), settled: nil)
                    }
                }
            }
            if let note = detail.expense.note, !note.isEmpty {
                Section("备注") {
                    Text(note)
                        .textSelection(.enabled)
                }
            }
            Section {
            } footer: {
                Text("\(detail.expense.source == .agent ? "由 Agent 记录" : "手动记录") · \(detail.expense.createdAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func header(_ detail: ExpenseDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let category = detail.expense.category {
                Text(category)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(detail.expense.merchant)
                .font(.title2.weight(.semibold))
            Text(detail.total.formatted)
                .font(.largeTitle.weight(.bold))
                .monospacedDigit()
            if let settled = detail.settled(detail.total.minor) {
                Text("≈ \(settled.formatted)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(occurredLabel(detail.expense))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func occurredLabel(_ expense: Expense) -> String {
        let zone = TimeZone(identifier: expense.timeZone) ?? .current
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = zone
        let label = expense.occurredAt.formatted(style)
        guard zone.secondsFromGMT(for: expense.occurredAt) != TimeZone.current.secondsFromGMT(for: expense.occurredAt) else { return label }
        return "\(label) · \(zone.localizedName(for: .shortGeneric, locale: .current) ?? zone.identifier)"
    }

    private static func methodName(_ method: String) -> String {
        switch method {
        case "cash": "现金"
        case "card": "信用卡"
        case "alipay": "支付宝"
        case "wechat": "微信支付"
        default: method
        }
    }
}

private struct AmountRow: View {
    var title: String
    var subtitle: String?
    var amount: Money
    var settled: Money?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amount.formatted)
                    .monospacedDigit()
                if let settled {
                    Text("≈ \(settled.formatted)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

final class ExpenseDetailViewController: UIHostingController<ExpenseDetailView> {
    private var observation: AnyDatabaseCancellable?

    init(expenseId: UUID, myParticipantId: UUID?) {
        super.init(rootView: ExpenseDetailView(detail: nil, myParticipantId: myParticipantId))
        navigationItem.largeTitleDisplayMode = .never
        rootView.onOpenMap = { [weak self] placeId in self?.openMap(placeId: placeId) }
        let store = AppServices.store
        observation = store.observeExpenseDetail(expenseId: expenseId).start(in: store.writer, scheduling: .immediate, onError: { _ in }) { [weak self] detail in
            self?.rootView.detail = detail
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func openMap(placeId: UUID) {
        guard let ledgerId = rootView.detail?.expense.ledgerId else { return }
        let store = AppServices.store
        guard let ledger = try? store.writer.read({ db in try Ledger.fetchOne(db, key: ledgerId.uuidString) }) else { return }
        navigationController?.pushViewController(ActivityViewController(ledger: ledger, initialPlaceId: placeId), animated: true)
    }
}
