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
    private let startOnMap: Bool
    private var rows: [UUID: ActivityRow] = [:]
    private var settlement = Settlement(currency: "", rows: [], missingRates: [])
    private var myParticipantId: UUID?
    private var observations: [AnyDatabaseCancellable] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let askButton = UIButton(configuration: .prominentGlass())
    private let segmentedControl = UISegmentedControl(items: ["Activity", "Map"])
    private var mapController: LedgerMapViewController!

    init(ledger: Ledger, startOnMap: Bool = false) {
        self.ledger = ledger
        self.startOnMap = startOnMap
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.subtitle = ledger.name
        navigationItem.backButtonTitle = ledger.name
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            navigationController?.pushViewController(LedgerSettingsViewController(ledgerId: ledger.id), animated: true)
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()
        configureSegmentedControl()
        configureMapController()
        loadMyParticipant()
        observe()
        if startOnMap {
            segmentedControl.selectedSegmentIndex = 1
            segmentChanged()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
            collectionView.deselectItem(at: indexPath, animated: animated)
        }
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)

        askButton.configuration?.title = "Ask Agent…"
        askButton.configuration?.image = UIImage(systemName: "sparkles")
        askButton.configuration?.imagePadding = 8
        askButton.configuration?.cornerStyle = .capsule
        askButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        askButton.translatesAutoresizingMaskIntoConstraints = false
        askButton.addAction(UIAction { [weak self] _ in self?.openChat() }, for: .primaryActionTriggered)
        view.addSubview(askButton)
        NSLayoutConstraint.activate([
            askButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            askButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            askButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        collectionView.contentInset.bottom = 72
        collectionView.verticalScrollIndicatorInsets.bottom = 72
    }

    private func configureSegmentedControl() {
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.accessibilityIdentifier = "activity-map-segment"
        segmentedControl.addAction(UIAction { [weak self] _ in self?.segmentChanged() }, for: .valueChanged)
        navigationItem.titleView = segmentedControl
    }

    private func configureMapController() {
        let controller = LedgerMapViewController(ledgerId: ledger.id)
        controller.onPreviewVisibilityChanged = { [weak self] visible in
            self?.askButton.isHidden = visible
        }
        controller.onOpenExpense = { [weak self] id in
            guard let self else { return }
            navigationController?.pushViewController(ExpenseDetailViewController(expenseId: id, myParticipantId: myParticipantId), animated: true)
        }
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.isHidden = true
        view.insertSubview(controller.view, belowSubview: askButton)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
        mapController = controller
    }

    private func segmentChanged() {
        let showMap = segmentedControl.selectedSegmentIndex == 1
        mapController.view.isHidden = !showMap
        askButton.isHidden = showMap && mapController.isPreviewVisible
    }

    private func openChat() {
        guard let chat = try? ChatViewController(ledger: ledger) else { return }
        navigationController?.pushViewController(chat, animated: true)
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [unowned self] cell, _, item in
            switch item {
            case .balance:
                cell.contentConfiguration = UIHostingConfiguration {
                    BalanceCardView(settlement: settlement, myParticipantId: myParticipantId)
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
        observations.append(store.observeSettlement(ledgerId: ledger.id).start(in: store.writer, scheduling: .immediate, onError: { _ in }) { [weak self] settlement in
            self?.settlement = settlement
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

extension ActivityViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .expense = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .expense(let id) = dataSource.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(ExpenseDetailViewController(expenseId: id, myParticipantId: myParticipantId), animated: true)
    }
}

private extension ActivityRow {
    var day: DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        return calendar.dateComponents([.year, .month, .day], from: occurredAt)
    }
}
