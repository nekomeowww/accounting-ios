import GRDB
import LedgerDomain
import LedgerPersistence
import SwiftUI

struct ProposalPreview {
    var merchant: String
    var total: Money
    var settled: Money?
    var payer: String
    var consumers: [String]
    var occurredAt: Date
    var category: String?
    var note: String?

    static func make(payload: String?, ledger: Ledger, store: LedgerStore) -> Result<ProposalPreview, Error> {
        Result {
            let participants = try store.participants(ledgerId: ledger.id)
            let names = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.name) })
            let draft = try ExpenseProposal.decode(payload ?? "").draft(ledgerId: ledger.id, participants: participants.map { (id: $0.id, name: $0.name) })
            let total = Money(minor: draft.totalMinor, currency: draft.currency)
            let (settlement, rate) = try store.writer.read { db in
                let settlement = try Ledger.fetchOne(db, key: ledger.id.uuidString)?.settlementCurrency ?? ledger.settlementCurrency
                let rate = try LedgerStore.fetchRates(db, ledgerId: ledger.id).first { $0.currency == draft.currency }?.rate
                return (settlement, rate)
            }
            return ProposalPreview(
                merchant: draft.merchant,
                total: total,
                settled: settlement != draft.currency ? rate.map { total.converted(to: settlement, rate: $0) } : nil,
                payer: draft.payments.compactMap { names[$0.participantId] }.joined(separator: "、"),
                consumers: draft.lines.flatMap(\.consumers).compactMap { names[$0.participantId] },
                occurredAt: draft.occurredAt,
                category: draft.category,
                note: draft.note
            )
        }
    }
}

enum ProposalPlaceRow {
    case searching
    case auto(candidates: [Candidate], selected: Candidate?)
    case multiple(hintName: String, candidates: [Candidate], selected: Candidate?)
    case unresolved
    case fixed(name: String, subtitle: String?)
}

struct ProposalCardView: View {
    var state: ProposalState
    var preview: Result<ProposalPreview, Error>
    var placeRow: ProposalPlaceRow?
    var onAccept: () -> Void
    var onDismiss: () -> Void
    var onOpen: () -> Void
    var onSelectPlace: (Candidate?) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("记账卡片", systemImage: "square.and.pencil")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            switch preview {
            case .success(let preview): details(preview)
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            actions
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .opacity(state == .dismissed ? 0.55 : 1)
        .padding(.vertical, 4)
    }

    private func details(_ preview: ProposalPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(preview.merchant)
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(preview.total.formatted)
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                    if let settled = preview.settled {
                        Text("≈ \(settled.formatted)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("付款", preview.payer)
                row("分摊", preview.consumers.count == 1 ? "\(preview.consumers[0]) 个人" : "\(preview.consumers.joined(separator: "、"))（\(preview.consumers.count) 人均分）")
                row("时间", preview.occurredAt.formatted(date: .abbreviated, time: .shortened))
                if let category = preview.category { row("分类", category) }
                if let note = preview.note, !note.isEmpty { row("备注", note) }
            }
            .font(.subheadline)
            placeRowContent
        }
    }

    @ViewBuilder
    private var placeRowContent: some View {
        if let placeRow {
            switch placeRow {
            case .searching:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("📍 地点解析中…")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            case .fixed(let name, let subtitle):
                Text("📍 " + (subtitle.map { "\(name) · \($0)" } ?? name))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .unresolved:
                Text("📍 地点待确认")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .auto(let candidates, let selected):
                placeMenu(candidates: candidates, selected: selected) {
                    "📍 " + (selected.map(candidateLabel) ?? "不关联地点")
                }
            case .multiple(let hintName, let candidates, let selected):
                placeMenu(candidates: candidates, selected: selected) {
                    "📍 \(selected?.name ?? hintName) · \(candidates.count) 个候选"
                }
            }
        }
    }

    private func placeMenu(candidates: [Candidate], selected: Candidate?, label: () -> String) -> some View {
        Menu {
            ForEach(candidates, id: \.self) { candidate in
                Button {
                    onSelectPlace(candidate)
                } label: {
                    if candidate == selected {
                        Label(candidateLabel(candidate), systemImage: "checkmark")
                    } else {
                        Text(candidateLabel(candidate))
                    }
                }
            }
            Button("不关联地点", role: .destructive) { onSelectPlace(nil) }
        } label: {
            Text(label())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func candidateLabel(_ candidate: Candidate) -> String {
        candidate.address.map { "\(candidate.name) · \($0)" } ?? candidate.name
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .pending:
            HStack {
                Button("取消", role: .cancel, action: onDismiss)
                    .buttonStyle(.bordered)
                Spacer()
                if case .success = preview {
                    Button("记账", action: onAccept)
                        .buttonStyle(.borderedProminent)
                }
            }
        case .accepted:
            Button(action: onOpen) {
                Label("已记账", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.bordered)
            .tint(.green)
        case .dismissed:
            Text("已取消")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
