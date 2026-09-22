import LedgerDomain
import LedgerPersistence
import SwiftUI

struct ExpenseRowView: View {
    var row: ActivityRow

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.merchant)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.total.formatted)
                .font(.body.weight(.semibold))
                .monospacedDigit()
        }
    }

    private var subtitle: String {
        switch row.consumerCount {
        case 0: row.payerNames
        case 1: "\(row.payerNames) 支付 · 个人消费"
        default: "\(row.payerNames) 支付 · \(row.consumerCount) 人分摊"
        }
    }
}

struct BalanceCardView: View {
    var balances: [BalanceRow]
    var myParticipantId: UUID?
    var currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let primary = mine.first {
                Text(primary.netMinor >= 0 ? "你应收" : "你应付")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Money(minor: abs(primary.netMinor), currency: primary.currency).formatted)
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
            }
            if mine.count > 1 {
                Text(mine.dropFirst().map { "\($0.netMinor >= 0 ? "应收" : "应付") \(Money(minor: abs($0.netMinor), currency: $0.currency).formatted)" }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ForEach(others, id: \.self) { row in
                HStack {
                    Text(row.participantName)
                    Spacer()
                    Text(Money(minor: abs(row.netMinor), currency: row.currency).formatted)
                        .monospacedDigit()
                        .foregroundStyle(row.netMinor < 0 ? .orange : .green)
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    private var mine: [BalanceRow] {
        balances.filter { $0.participantId == myParticipantId }.sorted { ($0.currency == currency ? 0 : 1, $0.currency) < ($1.currency == currency ? 0 : 1, $1.currency) }
    }

    private var others: [BalanceRow] {
        balances.filter { $0.participantId != myParticipantId && $0.netMinor != 0 }
    }
}

struct DayHeaderView: View {
    var day: DateComponents

    var body: some View {
        Text(label)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }

    private var label: String {
        let calendar = Calendar.current
        let today = calendar.dateComponents([.year, .month, .day], from: .now)
        let yesterday = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: -1, to: .now)!)
        if day == today { return "今天" }
        if day == yesterday { return "昨天" }
        return calendar.date(from: day)?.formatted(date: .abbreviated, time: .omitted) ?? ""
    }
}
