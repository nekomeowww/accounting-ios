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
        let base = switch (row.kind, row.consumerCount) {
        case (.transfer, _): "还款"
        case (_, 0): row.payerNames
        case (_, 1): "\(row.payerNames) 支付 · 个人消费"
        default: "\(row.payerNames) 支付 · \(row.consumerCount) 人分摊"
        }
        guard let endsAt = row.endsAt else { return base }
        return "\(base) · \(ExpenseDates.label(row.occurredAt, endsAt, timeZone: TimeZone(identifier: row.timeZone) ?? .current))"
    }
}

struct BalanceCardView: View {
    var settlement: Settlement
    var myParticipantId: UUID?
    var onSettle: (PlannedTransfer) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mine {
                Text(mine.net.minor == 0 ? "你已两清" : mine.net.minor > 0 ? "你应收" : "你应付")
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
            if settlement.transfers.isEmpty {
                if !settlement.rows.isEmpty && settlement.missingRates.isEmpty {
                    Label("已结清", systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            } else {
                Divider()
                Text("结清方式")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(settlement.transfers, id: \.self) { transfer in
                    Button { onSettle(transfer) } label: {
                        TransferRow(
                            from: settlement.name(transfer.from),
                            to: settlement.name(transfer.to),
                            amount: Money(minor: transfer.minor, currency: settlement.currency),
                            involvesMe: transfer.from == myParticipantId || transfer.to == myParticipantId
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("记录这笔还款")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var mine: SettlementRow? {
        settlement.rows.first { $0.participantId == myParticipantId }
    }
}

private struct TransferRow: View {
    var from: String
    var to: String
    var amount: Money
    var involvesMe: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(from)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(to)
            Spacer()
            Text(amount.formatted)
                .monospacedDigit()
        }
        .font(.subheadline.weight(involvesMe ? .semibold : .regular))
        .foregroundStyle(involvesMe ? .primary : .secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(from) 转给 \(to) \(amount.formatted)")
    }
}

enum ExpenseDates {
    static func label(_ start: Date, _ end: Date?, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: end == nil ? .shortened : .omitted)
        style.timeZone = timeZone
        guard let end else { return start.formatted(style) }
        var short = Date.FormatStyle().month(.abbreviated).day()
        short.timeZone = timeZone
        return "\(start.formatted(short)) – \(end.formatted(style))"
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
