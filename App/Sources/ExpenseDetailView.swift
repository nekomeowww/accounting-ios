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
            if let original = detail.expense.original {
                Text("标价 \(original.formatted)")
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
        let label = ExpenseDates.label(expense.occurredAt, expense.endsAt, timeZone: zone)
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

    private let expenseId: UUID

    init(expenseId: UUID, myParticipantId: UUID?) {
        self.expenseId = expenseId
        super.init(rootView: ExpenseDetailView(detail: nil, myParticipantId: myParticipantId))
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [
            UIAction(title: "编辑", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.edit() },
            UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.confirmDelete() },
        ]))
        rootView.onOpenMap = { [weak self] placeId in self?.openMap(placeId: placeId) }
        let store = AppServices.store
        observation = store.observeExpenseDetail(expenseId: expenseId).start(in: store.writer, scheduling: .immediate, onError: { _ in }) { [weak self] detail in
            self?.rootView.detail = detail
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var ledger: Ledger? {
        guard let ledgerId = rootView.detail?.expense.ledgerId else { return nil }
        return try? AppServices.store.writer.read { try Ledger.fetchOne($0, key: ledgerId.uuidString) }
    }

    private func edit() {
        guard let ledger else { return }
        let id = expenseId
        ExpenseForm.present(from: self, ledger: ledger, expenseId: id) { [weak self] previous in
            guard let self, let previous else { return }
            UndoToast.show(in: view, message: "已修改") {
                let current = try AppServices.store.editableExpense(id: id)
                try AppServices.store.updateExpense(id: id, previous.draft, expectedVersion: current.version)
            }
        }
    }

    private func confirmDelete() {
        guard let merchant = rootView.detail?.expense.merchant else { return }
        let alert = UIAlertController(title: "删除「\(merchant)」？", message: "余额会随之更新。", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let id = expenseId
            do {
                try AppServices.store.deleteExpense(id: id)
            } catch {
                let failure = UIAlertController(title: "删除失败", message: error.localizedDescription, preferredStyle: .alert)
                failure.addAction(UIAlertAction(title: "好", style: .default))
                present(failure, animated: true)
                return
            }
            let container = navigationController?.view ?? view!
            navigationController?.popViewController(animated: true)
            UndoToast.show(in: container, message: "已删除「\(merchant)」") {
                try AppServices.store.restoreExpense(id: id)
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func openMap(placeId: UUID) {
        guard let ledgerId = rootView.detail?.expense.ledgerId else { return }
        let store = AppServices.store
        guard let ledger = try? store.writer.read({ db in try Ledger.fetchOne(db, key: ledgerId.uuidString) }) else { return }
        navigationController?.pushViewController(ActivityViewController(ledger: ledger, initialPlaceId: placeId), animated: true)
    }
}
