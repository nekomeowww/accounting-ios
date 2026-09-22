import GRDB
import LedgerDomain
import SwiftUI
import UIKit

final class LedgerListViewController: UIHostingController<LedgerListView> {
    private var observation: AnyDatabaseCancellable?

    init() {
        super.init(rootView: LedgerListView(ledgers: [], onSelect: { _ in }))
        title = "账本"
        navigationItem.largeTitleDisplayMode = .always
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.navigationBar.prefersLargeTitles = true
        observation = AppServices.store.observeLedgers().start(
            in: AppServices.store.writer,
            scheduling: .immediate,
            onError: { _ in },
            onChange: { [weak self] ledgers in self?.render(ledgers) }
        )
    }

    private func render(_ ledgers: [Ledger]) {
        rootView = LedgerListView(ledgers: ledgers) { [weak self] ledger in
            self?.navigationController?.pushViewController(ActivityViewController(ledger: ledger), animated: true)
        }
    }
}
