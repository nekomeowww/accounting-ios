import GRDB
import LedgerDomain
import LedgerPersistence
import SwiftUI
import UIKit

struct LedgerStatsView: View {
    var stats: LedgerStats?

    var body: some View {
        if let stats {
            List {
                if !stats.missingRates.isEmpty {
                    Label("缺少 \(stats.missingRates.joined(separator: "、")) 汇率，未计入", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Section {
                    ForEach(stats.people, id: \.participantId) { person in
                        StatsRow(title: person.name, shared: person.shared, personal: person.personal, total: person.total)
                    }
                    StatsRow(title: "合计", shared: sum(stats.people.map(\.shared), stats.currency),
                             personal: sum(stats.people.map(\.personal), stats.currency),
                             total: sum(stats.people.map(\.total), stats.currency))
                        .fontWeight(.semibold)
                } header: {
                    Text("每人总花费")
                } footer: {
                    Text("共同 = 多人分摊中自己的份额；个人 = 只有自己参与的消费。")
                }
                Section("分类") {
                    ForEach(stats.categories, id: \.name) { category in
                        StatsRow(title: category.name, shared: category.shared, personal: category.personal, total: category.total)
                    }
                }
            }
            .listStyle(.insetGrouped)
        } else {
            ProgressView()
        }
    }

    private func sum(_ values: [Money], _ currency: String) -> Money {
        Money(minor: values.reduce(0) { $0 + $1.minor }, currency: currency)
    }
}

private struct StatsRow: View {
    var title: String
    var shared: Money
    var personal: Money
    var total: Money

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("共同 \(shared.formatted) · 个人 \(personal.formatted)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Text(total.formatted)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

final class LedgerStatsViewController: UIHostingController<LedgerStatsView> {
    private var observation: AnyDatabaseCancellable?

    init(ledgerId: UUID) {
        super.init(rootView: LedgerStatsView())
        title = "统计"
        navigationItem.largeTitleDisplayMode = .never
        let store = AppServices.store
        observation = store.observeStats(ledgerId: ledgerId).start(in: store.writer, scheduling: .immediate, onError: { _ in }) { [weak self] stats in
            self?.rootView.stats = stats
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
