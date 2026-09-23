import GRDB
import LedgerDomain
import LedgerPersistence
import SwiftUI
import UIKit

struct ExpenseFormView: View {
    static let categories = ["餐饮", "交通", "住宿", "门票", "购物", "其他"]

    let participants: [Participant]
    let currencies: [String]
    let base: ExpenseDraft
    var onCancel: () -> Void
    var onSave: (ExpenseDraft) throws -> Void

    @State private var merchant: String
    @State private var amount: String
    @State private var currency: String
    @State private var payer: UUID
    @State private var consumers: Set<UUID>
    @State private var exactMode: Bool
    @State private var exactAmounts: [UUID: String]
    @State private var occurredAt: Date
    @State private var spansDays: Bool
    @State private var endsAt: Date
    @State private var category: String
    @State private var note: String
    @State private var hasOriginal: Bool
    @State private var originalAmount: String
    @State private var originalCurrency: String
    @State private var error: String?

    init(participants: [Participant], currencies: [String], base: ExpenseDraft, onCancel: @escaping () -> Void, onSave: @escaping (ExpenseDraft) throws -> Void) {
        self.participants = participants
        self.currencies = currencies
        self.base = base
        self.onCancel = onCancel
        self.onSave = onSave
        _merchant = State(initialValue: base.merchant)
        _amount = State(initialValue: base.totalMinor > 0 ? Money(minor: base.totalMinor, currency: base.currency).plainText : "")
        _currency = State(initialValue: base.currency)
        _payer = State(initialValue: base.payments.first?.participantId ?? participants.first!.id)
        _consumers = State(initialValue: Set(base.lines.first?.consumers.map(\.participantId) ?? participants.map(\.id)))
        let exactLine = base.lines.count == 1 && base.lines[0].splitRule == .exact ? base.lines[0] : nil
        _exactMode = State(initialValue: exactLine != nil)
        _exactAmounts = State(initialValue: Dictionary(uniqueKeysWithValues: (exactLine?.consumers ?? []).compactMap { consumer in
            consumer.exactMinor.map { (consumer.participantId, Money(minor: $0, currency: base.currency).plainText) }
        }))
        _occurredAt = State(initialValue: base.occurredAt)
        _spansDays = State(initialValue: base.endsAt != nil)
        _endsAt = State(initialValue: base.endsAt ?? base.occurredAt.addingTimeInterval(86400))
        _category = State(initialValue: base.category ?? "")
        _note = State(initialValue: base.note ?? "")
        _hasOriginal = State(initialValue: base.original != nil)
        _originalAmount = State(initialValue: base.original?.plainText ?? "")
        _originalCurrency = State(initialValue: base.original?.currency ?? currencies.first { $0 != base.currency } ?? "JPY")
    }

    private var isItemized: Bool { base.lines.count > 1 }
    private var timeZone: TimeZone { TimeZone(identifier: base.timeZone) ?? .current }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("商户或事项", text: $merchant)
                    HStack {
                        TextField("金额", text: $amount)
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
                            .disabled(isItemized)
                        Picker("币种", selection: $currency) {
                            ForEach(currencies, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .disabled(isItemized)
                    }
                    Picker("分类", selection: $category) {
                        Text("未分类").tag("")
                        ForEach(Self.categories + (Self.categories.contains(category) || category.isEmpty ? [] : [category]), id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("付款人") {
                    Picker("付款人", selection: $payer) {
                        ForEach(participants) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                }
                if isItemized {
                    Section {
                        ForEach(base.lines, id: \.self) { line in
                            HStack {
                                Text(line.name)
                                Spacer()
                                Text(Money(minor: line.amountMinor, currency: base.currency).formatted).monospacedDigit()
                            }
                        }
                    } header: {
                        Text("项目明细")
                    } footer: {
                        Text("多项目账单的金额和分摊暂时只能通过 Agent 修改。")
                    }
                } else {
                    Section {
                        Picker("分摊方式", selection: $exactMode) {
                            Text("均分").tag(false)
                            Text("指定金额").tag(true)
                        }
                        .pickerStyle(.segmented)
                        ForEach(participants) { participant in
                            if exactMode {
                                HStack {
                                    Text(participant.name)
                                    TextField("0", text: Binding(
                                        get: { exactAmounts[participant.id] ?? "" },
                                        set: { exactAmounts[participant.id] = $0 }
                                    ))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                }
                            } else {
                                Toggle(participant.name, isOn: Binding(
                                    get: { consumers.contains(participant.id) },
                                    set: { if $0 { consumers.insert(participant.id) } else { consumers.remove(participant.id) } }
                                ))
                            }
                        }
                    } header: {
                        Text(exactMode ? "按金额分摊" : "参与分摊 · \(consumers.count) 人")
                    } footer: {
                        if exactMode, let remaining = exactRemaining {
                            Text(remaining.minor == 0 ? "已分完" : remaining.minor > 0 ? "还差 \(remaining.formatted)" : "超出 \(Money(minor: -remaining.minor, currency: currency).formatted)")
                        }
                    }
                }
                Section {
                    DatePicker(spansDays ? "开始" : "时间", selection: $occurredAt)
                    Toggle("跨天（住宿、租车）", isOn: $spansDays)
                    if spansDays {
                        DatePicker("结束", selection: $endsAt, in: occurredAt...)
                    }
                }
                .environment(\.timeZone, timeZone)
                Section {
                    Toggle("标价币种不同", isOn: $hasOriginal)
                    if hasOriginal {
                        HStack {
                            TextField("标价金额", text: $originalAmount)
                                .keyboardType(.decimalPad)
                                .monospacedDigit()
                            Picker("标价币种", selection: $originalCurrency) {
                                ForEach(Set(currencies + [originalCurrency]).sorted(), id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                } footer: {
                    Text("如支付宝按人民币扣款、小票标价日元。")
                }
                Section("备注") {
                    TextField("备注", text: $note, axis: .vertical)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(base.totalMinor > 0 ? "编辑消费" : "记一笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(merchant.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
    }

    private var exactRemaining: Money? {
        guard let total = Money(parsing: amount, currency: currency) else { return nil }
        let assigned = exactAmounts.values.compactMap { Money(parsing: $0, currency: currency)?.minor }.reduce(0, +)
        return Money(minor: total.minor - assigned, currency: currency)
    }

    private func save() {
        do {
            try onSave(makeDraft())
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func makeDraft() throws -> ExpenseDraft {
        var draft = base
        draft.merchant = merchant.trimmingCharacters(in: .whitespaces)
        draft.category = category.isEmpty ? nil : category
        draft.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        draft.occurredAt = occurredAt
        draft.endsAt = spansDays ? endsAt : nil
        draft.currency = currency
        if hasOriginal {
            guard let original = Money(parsing: originalAmount, currency: originalCurrency) else { throw FormError("标价金额无效") }
            draft.original = original
        } else {
            draft.original = nil
        }
        let total: Int64
        if isItemized {
            total = base.totalMinor
        } else {
            guard let money = Money(parsing: amount, currency: currency) else { throw FormError("金额无效") }
            total = money.minor
            if exactMode {
                var shares: [ConsumerDraft] = []
                for participant in participants {
                    let text = (exactAmounts[participant.id] ?? "").trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty, text != "0" else { continue }
                    guard let share = Money(parsing: text, currency: currency) else { throw FormError("\(participant.name) 的金额无效") }
                    shares.append(ConsumerDraft(participant.id, exactMinor: share.minor))
                }
                guard !shares.isEmpty else { throw FormError("至少填写一位参与人的金额") }
                guard exactRemaining?.minor == 0 else { throw FormError("每人金额合计需等于总额") }
                draft.lines = [LineDraft(name: draft.merchant, amountMinor: total, splitRule: .exact, consumers: shares)]
            } else {
                guard !consumers.isEmpty else { throw FormError("至少选择一位参与人") }
                let ordered = participants.map(\.id).filter(consumers.contains)
                draft.lines = [LineDraft(name: draft.merchant, amountMinor: total, consumers: ordered.map { ConsumerDraft($0) })]
            }
        }
        let method = base.payments.first { $0.participantId == payer }?.method
        draft.payments = [PaymentDraft(payer, amountMinor: total, method: method)]
        return draft
    }
}

private struct FormError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum ExpenseForm {
    @MainActor
    static func present(from presenter: UIViewController, ledger: Ledger, expenseId: UUID? = nil, onSaved: @escaping (_ previous: EditableExpense?) -> Void = { _ in }) {
        let store = AppServices.store
        do {
            let participants = try store.participants(ledgerId: ledger.id)
            guard !participants.isEmpty else { return }
            let editable = try expenseId.map { try store.editableExpense(id: $0) }
            let inUse = try store.writer.read { try LedgerStore.fetchCurrenciesInUse($0, ledgerId: ledger.id) }
            let base = editable?.draft ?? ExpenseDraft(
                ledgerId: ledger.id, merchant: "", occurredAt: .now, currency: ledger.defaultCurrency, lines: [],
                payments: [PaymentDraft(myParticipantId(ledger) ?? participants[0].id, amountMinor: 0)]
            )
            let currencies = Set(inUse + [ledger.defaultCurrency, ledger.settlementCurrency, base.currency]).sorted()
            var controller: UIViewController?
            let form = ExpenseFormView(participants: participants, currencies: currencies, base: base) {
                controller?.dismiss(animated: true)
            } onSave: { draft in
                if let expenseId, let editable {
                    try store.updateExpense(id: expenseId, draft, expectedVersion: editable.version)
                } else {
                    try store.createExpense(draft)
                }
                controller?.dismiss(animated: true)
                onSaved(editable)
            }
            controller = UIHostingController(rootView: form)
            presenter.present(controller!, animated: true)
        } catch {
            let alert = UIAlertController(title: "无法打开", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            presenter.present(alert, animated: true)
        }
    }

    @MainActor
    static func myParticipantId(_ ledger: Ledger) -> UUID? {
        let store = AppServices.store
        return try? store.writer.read { db in
            try Member.filter(GRDB.Column("ledgerId") == ledger.id.uuidString && GRDB.Column("actorId") == store.actorId.uuidString)
                .fetchOne(db)?.participantId
        }
    }
}
