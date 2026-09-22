import GRDB
import LedgerDomain
import LedgerPersistence
import SwiftUI
import UIKit

final class ActivityViewController: UIViewController {
    private enum Section: Hashable {
        case summary
        case day(DateComponents)
    }

    private enum Item: Hashable {
        case balance
        case expense(UUID)
    }

    private let ledger: Ledger
    private var rows: [UUID: ActivityRow] = [:]
    private var balances: [BalanceRow] = []
    private var myParticipantId: UUID?
    private var observations: [AnyDatabaseCancellable] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(ledger: Ledger) {
        self.ledger = ledger
        super.init(nibName: nil, bundle: nil)
        title = ledger.name
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()
        loadMyParticipant()
        observe()
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [unowned self] cell, _, item in
            switch item {
            case .balance:
                cell.contentConfiguration = UIHostingConfiguration {
                    BalanceCardView(balances: balances, myParticipantId: myParticipantId, currency: ledger.defaultCurrency)
                }
            case .expense(let id):
                guard let row = rows[id] else { return }
                cell.contentConfiguration = UIHostingConfiguration { ExpenseRowView(row: row) }
                cell.accessories = [.disclosureIndicator()]
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [unowned self] view, _, indexPath in
            guard case .day(let day) = dataSource.sectionIdentifier(for: indexPath.section) else {
                view.contentConfiguration = nil
                return
            }
            view.contentConfiguration = UIHostingConfiguration { DayHeaderView(day: day) }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func loadMyParticipant() {
        let store = AppServices.store
        myParticipantId = try? store.writer.read { db in
            try Member.filter(Column("ledgerId") == ledger.id.uuidString && Column("actorId") == store.actorId.uuidString)
                .fetchOne(db)?.participantId
        }
    }

    private func observe() {
        let store = AppServices.store
        observations.append(store.observeActivity(ledgerId: ledger.id).start(in: store.writer, scheduling: .immediate, onError: { _ in }) { [weak self] rows in
            self?.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            self?.applySnapshot(rows)
        })
        observations.append(store.observeBalances(ledgerId: ledger.id).start(in: store.writer, scheduling: .immediate, onError: { _ in }) { [weak self] balances in
            self?.balances = balances
            self?.reloadBalance()
        })
    }

    private func applySnapshot(_ rows: [ActivityRow]) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.summary])
        snapshot.appendItems([.balance], toSection: .summary)
        let grouped = Dictionary(grouping: rows) { $0.day }
        for day in grouped.keys.sorted(by: { ($0.year!, $0.month!, $0.day!) > ($1.year!, $1.month!, $1.day!) }) {
            snapshot.appendSections([.day(day)])
            snapshot.appendItems(grouped[day]!.map { .expense($0.id) }, toSection: .day(day))
        }
        snapshot.reconfigureItems(rows.map { .expense($0.id) }.filter { snapshot.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    private func reloadBalance() {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(.balance) != nil else { return }
        snapshot.reconfigureItems([.balance])
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

private extension ActivityRow {
    var day: DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        return calendar.dateComponents([.year, .month, .day], from: occurredAt)
    }
}
