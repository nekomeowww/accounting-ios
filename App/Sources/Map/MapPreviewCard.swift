import LedgerDomain
import LedgerPersistence
import SwiftUI

struct MapPreviewCard: View {
    var pin: LedgerPersistence.MapPin
    var settlementCurrency: String?
    var rates: [String: Decimal]
    var onSelectExpense: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pin.expenses.count == 1, let expense = pin.expenses.first {
                singleContent(expense)
            } else {
                multiContent
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var placeTitle: String {
        if let branch = pin.place.branch, !branch.isEmpty {
            return "\(pin.place.name) \(branch)"
        }
        return pin.place.name
    }

    private func singleContent(_ expense: LedgerPersistence.MapPin.ExpenseRef) -> some View {
        Button { onSelectExpense(expense.expenseId) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(placeTitle)
                    .font(.headline)
                Text(timeLabel(expense))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(money(expense).formatted)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                    if let converted = convertedMoney(expense) {
                        Text("≈ \(converted.formatted)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(payerLabel(expense))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var multiContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(placeTitle)
                .font(.headline)
            ForEach(pin.expenses, id: \.expenseId) { expense in
                Button { onSelectExpense(expense.expenseId) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(expense.merchant)
                                .font(.subheadline)
                            Text(timeLabel(expense))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(expense).formatted)
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Text("合计")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(totalLabel)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
        }
    }

    private var totalLabel: String {
        if let total = pin.total { return total.formatted }
        let currencies = Set(pin.expenses.map(\.currency))
        guard let currency = currencies.count == 1 ? currencies.first : nil else { return "-" }
        return Money(minor: pin.expenses.reduce(0) { $0 + $1.totalMinor }, currency: currency).formatted
    }

    private func money(_ expense: LedgerPersistence.MapPin.ExpenseRef) -> Money {
        Money(minor: expense.totalMinor, currency: expense.currency)
    }

    private func convertedMoney(_ expense: LedgerPersistence.MapPin.ExpenseRef) -> Money? {
        guard let settlementCurrency, expense.currency != settlementCurrency, let rate = rates[expense.currency] else { return nil }
        return money(expense).converted(to: settlementCurrency, rate: rate)
    }

    private func payerLabel(_ expense: LedgerPersistence.MapPin.ExpenseRef) -> String {
        switch expense.consumerCount {
        case 0: expense.payerNames
        case 1: "\(expense.payerNames) 支付 · 个人消费"
        default: "\(expense.payerNames) 支付 · \(expense.consumerCount) 人分摊"
        }
    }

    private func timeLabel(_ expense: LedgerPersistence.MapPin.ExpenseRef) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = TimeZone(identifier: expense.timeZone) ?? .current
        return expense.occurredAt.formatted(style)
    }
}
