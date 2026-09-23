import LedgerDomain
import LedgerPersistence
import SwiftUI

struct RepaymentCardView: View {
    var state: ProposalState
    var repayment: Result<RepaymentProposal.Resolved, Error>
    var names: [UUID: String]
    var onAccept: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("还款卡片", systemImage: "arrow.left.arrow.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            switch repayment {
            case .success(let repayment):
                HStack(alignment: .firstTextBaseline) {
                    Text("\(names[repayment.from] ?? "") → \(names[repayment.to] ?? "")")
                        .font(.headline)
                    Spacer()
                    Text(repayment.amount.formatted)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                if let note = repayment.note, !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            switch state {
            case .pending:
                HStack {
                    Button("取消", role: .cancel, action: onDismiss)
                        .buttonStyle(.bordered)
                    Spacer()
                    if case .success = repayment {
                        Button("记录还款", action: onAccept)
                            .buttonStyle(.borderedProminent)
                    }
                }
            case .accepted:
                Label("已记录", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .dismissed:
                Text("已取消")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .opacity(state == .dismissed ? 0.55 : 1)
        .padding(.vertical, 4)
    }
}
