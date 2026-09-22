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
    var settlement: Settlement
    var myParticipantId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mine {
                Text(mine.net.minor >= 0 ? "你应收" : "你应付")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Money(minor: abs(mine.net.minor), currency: mine.net.currency).formatted)
                    .font(.largeTitle.weight(.bold))
                    .monospacedDigit()
            }
            if !settlement.missingRates.isEmpty {
                Label("缺少 \(settlement.missingRates.joined(separator: "、")) 汇率，未计入", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(others, id: \.self) { row in
                HStack {
                    Text(row.participantName)
                    Spacer()
                    Text(Money(minor: abs(row.net.minor), currency: row.net.currency).formatted)
                        .monospacedDigit()
                        .foregroundStyle(row.net.minor < 0 ? .orange : .green)
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    private var mine: SettlementRow? {
        settlement.rows.first { $0.participantId == myParticipantId }
    }

    private var others: [SettlementRow] {
        settlement.rows.filter { $0.participantId != myParticipantId && $0.net.minor != 0 }
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
