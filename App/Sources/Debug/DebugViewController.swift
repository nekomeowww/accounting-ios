#if DEBUG
import GRDB
import LedgerDomain
import LedgerPersistence
import SwiftUI
import UIKit

struct DebugView: View {
    var counts: [(String, Int)]
    var onOpen: (String) -> Void
    var onReset: () -> Void
    @State private var confirmingReset = false

    var body: some View {
        List {
            Section("组件") {
                ForEach(DebugGallery.allCases) { row($0.id, $0.title, $0.symbol) }
            }
            Section("页面") {
                row("open-activity", "Activity", "list.bullet")
                row("open-map", "Map", "map")
                row("open-detail", "最近一笔消费详情", "doc.text.magnifyingglass")
                row("open-ledger-settings", "账本设置 / 汇率", "gearshape")
                row("open-chat", "Agent Chat", "sparkles")
                row("open-agent-settings", "AI 设置", "key")
            }
            Section("数据") {
                ForEach(counts, id: \.0) { table, count in
                    LabeledContent(table, value: "\(count)")
                        .monospacedDigit()
                }
                Button("重置示例数据", role: .destructive) { confirmingReset = true }
                    .accessibilityIdentifier("data-reset")
                    .confirmationDialog("清空本地数据库并重新写入示例账本？", isPresented: $confirmingReset, titleVisibility: .visible) {
                        Button("重置", role: .destructive, action: onReset)
                    }
            }
        }
    }

    private func row(_ id: String, _ title: String, _ symbol: String) -> some View {
        Button { onOpen(id) } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
        .accessibilityIdentifier(id)
    }
}

final class DebugViewController: UIHostingController<DebugView> {
    init() {
        super.init(rootView: DebugView(counts: [], onOpen: { _ in }, onReset: {}))
        title = "Debug"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        render()
    }

    private func render() {
        rootView = DebugView(
            counts: (try? DebugSeed.counts(AppServices.store)) ?? [],
            onOpen: { [weak self] in self?.open($0) },
            onReset: { [weak self] in
                try? DebugSeed.reset(AppServices.store)
                self?.render()
            }
        )
    }

    func open(_ id: String) {
        guard let controller = makeController(id) else { return }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func makeController(_ id: String) -> UIViewController? {
        let store = AppServices.store
        if let gallery = DebugGallery(rawValue: id) {
            let controller = UIHostingController(rootView: DebugGalleryView(gallery: gallery, fixtures: DebugFixtures.load(store: store)))
            controller.title = gallery.title
            return controller
        }
        guard let fixtures = DebugFixtures.load(store: store) else { return nil }
        switch id {
        case "open-activity":
            return ActivityViewController(ledger: fixtures.ledger)
        case "open-map":
            return ActivityViewController(ledger: fixtures.ledger, startOnMap: true)
        case "open-detail":
            guard let latest = try? store.writer.read({ try LedgerStore.fetchActivity($0, ledgerId: fixtures.ledger.id).first }) else { return nil }
            return ExpenseDetailViewController(expenseId: latest.id, myParticipantId: fixtures.me)
        case "open-ledger-settings":
            return LedgerSettingsViewController(ledgerId: fixtures.ledger.id)
        case "open-chat":
            return try? ChatViewController(ledger: fixtures.ledger)
        case "open-agent-settings":
            return AgentSettingsViewController()
        default:
            return nil
        }
    }
}
#endif
