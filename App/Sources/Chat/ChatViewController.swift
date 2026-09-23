import GRDB
import LedgerDomain
import LedgerPersistence
import SwiftUI
import UIKit

final class ChatViewController: UIViewController {
    private enum Section { case main }
    private enum PlaceLookup { case searching, candidates([Candidate]) }

    private let session: ChatSession
    private var messages: [UUID: Message] = [:]
    private var observation: AnyDatabaseCancellable?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, UUID>!
    private let composer = ChatComposerView()
    private var pinnedToBottom = true
    private var placeLookups: [UUID: PlaceLookup] = [:]
    private var placeOverrides: [UUID: ProposalPlaceChoice] = [:]
    private var images: [UUID: [UIImage]] = [:]

    init(ledger: Ledger) throws {
        session = try ChatSession(ledger: ledger)
        super.init(nibName: nil, bundle: nil)
        title = "Agent"
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureViews()
        configureDataSource()
        bindSession()
        observe()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshProviderState()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bottom = max(0, view.bounds.maxY - composer.frame.minY - view.safeAreaInsets.bottom) + 8
        guard collectionView.contentInset.bottom != bottom else { return }
        collectionView.contentInset.bottom = bottom
        collectionView.verticalScrollIndicatorInsets.bottom = bottom
    }

    private func configureViews() {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        composer.attachScrollEdge(to: collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        view.addSubview(composer)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        composer.onSend = { [weak self] text in
            guard let self, send(text) else { return }
            composer.clear()
        }
        composer.onStop = { [weak self] in self?.session.stop() }
        composer.onHeightChange = { [weak self] in self?.view.setNeedsLayout() }
        let openSettings: () -> Void = { [weak self] in
            self?.navigationController?.pushViewController(AgentSettingsViewController(), animated: true)
        }
        composer.onNoticeTap = openSettings
        composer.onModelTap = openSettings
    }

    @discardableResult
    func send(_ text: String, images: [AgentImage] = []) -> Bool {
        do {
            try session.send(text, images: images)
            pinnedToBottom = true
            return true
        } catch {
            let alert = UIAlertController(title: "发送失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
            return false
        }
    }

    private func configureDataSource() {
        let user = UICollectionView.CellRegistration<UICollectionViewListCell, Message> { [unowned self] cell, _, message in
            let photos = userImages(message.id)
            cell.contentConfiguration = UIHostingConfiguration { UserBubbleView(text: message.text, images: photos) }.margins(.vertical, 2)
        }
        let assistant = UICollectionView.CellRegistration<AssistantMessageCell, Message> { [unowned self] cell, _, message in
            let streaming = session.streamingMessageId == message.id
            cell.configure(text: streaming ? session.streamingText : message.text, streaming: streaming)
            cell.onHeightChange = { [weak self] in self?.relayoutStreamingCell() }
        }
        let proposal = UICollectionView.CellRegistration<UICollectionViewListCell, Message> { [unowned self] cell, _, message in
            let preview = ProposalPreview.make(payload: message.payload, createdAt: message.createdAt, ledger: session.ledger, store: AppServices.store)
            let occurredAt = (try? preview.get())?.occurredAt ?? message.createdAt
            cell.contentConfiguration = UIHostingConfiguration {
                ProposalCardView(
                    state: message.proposalState ?? .dismissed,
                    preview: preview,
                    placeRow: placeRow(for: message, occurredAt: occurredAt),
                    onAccept: { [weak self] in self?.accept(message) },
                    onDismiss: { [weak self] in self?.session.dismiss(message) },
                    onOpen: { [weak self] in self?.openExpense(message.expenseId) },
                    onSelectPlace: { [weak self] candidate in self?.selectPlace(candidate, for: message) }
                )
            }
        }
        let repayment = UICollectionView.CellRegistration<UICollectionViewListCell, Message> { [unowned self] cell, _, message in
            let participants = (try? AppServices.store.participants(ledgerId: session.ledger.id)) ?? []
            let resolved = Result { try RepaymentProposal.decode(message.payload ?? "").resolve(participants: participants.map { ($0.id, $0.name) }) }
            let names = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0.name) })
            cell.contentConfiguration = UIHostingConfiguration {
                RepaymentCardView(state: message.proposalState ?? .dismissed, repayment: resolved, names: names,
                                  onAccept: { [weak self] in self?.accept(message) },
                                  onDismiss: { [weak self] in self?.session.dismiss(message) })
            }
        }
        let failed = UICollectionView.CellRegistration<UICollectionViewListCell, Message> { [unowned self] cell, _, message in
            cell.contentConfiguration = UIHostingConfiguration {
                FailedMessageView(text: message.text, error: message.error ?? "失败") { [weak self] in
                    do { try self?.session.retry(message) }
                    catch {
                        let alert = UIAlertController(title: "重试失败", message: error.localizedDescription, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "好", style: .default))
                        self?.present(alert, animated: true)
                    }
                }
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [unowned self] collectionView, indexPath, id in
            guard let message = messages[id] else { return UICollectionViewCell() }
            if message.kind == .proposal {
                return collectionView.dequeueConfiguredReusableCell(using: proposal, for: indexPath, item: message)
            }
            if message.kind == .repayment {
                return collectionView.dequeueConfiguredReusableCell(using: repayment, for: indexPath, item: message)
            }
            switch (message.role, message.status) {
            case (.user, _):
                return collectionView.dequeueConfiguredReusableCell(using: user, for: indexPath, item: message)
            case (.assistant, .failed):
                return collectionView.dequeueConfiguredReusableCell(using: failed, for: indexPath, item: message)
            case (.assistant, _):
                return collectionView.dequeueConfiguredReusableCell(using: assistant, for: indexPath, item: message)
            }
        }
    }

    private func bindSession() {
        session.onStreamingUpdate = { [weak self] id, text in
            guard let self, let indexPath = dataSource.indexPath(for: id),
                  let cell = collectionView.cellForItem(at: indexPath) as? AssistantMessageCell else { return }
            cell.configure(text: text, streaming: session.streamingMessageId == id)
        }
        session.onStreamingStateChange = { [weak self] in
            guard let self else { return }
            composer.isStreaming = session.isStreaming
            composer.notice = session.toolStatus ?? (AgentSettings.load().isConfigured ? nil : "未配置 AI 服务，点击设置")
        }
        session.onRunError = { [weak self] message in
            let alert = UIAlertController(title: "保存失败", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            self?.present(alert, animated: true)
        }
    }

    private func observe() {
        let store = AppServices.store
        observation = store.observeMessages(conversationId: session.conversation.id).start(in: store.writer, scheduling: .immediate, onError: { _ in }) { [weak self] messages in
            self?.apply(messages)
        }
    }

    private func apply(_ list: [Message]) {
        let previous = messages
        messages = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(list.map(\.id))
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        var reload: [UUID] = []
        var reconfigure: [UUID] = []
        for message in list where existing.contains(message.id) {
            if previous[message.id].map(cellKind) != cellKind(message) {
                reload.append(message.id)
            } else if message.id != session.streamingMessageId {
                reconfigure.append(message.id)
            }
        }
        snapshot.reloadItems(reload)
        snapshot.reconfigureItems(reconfigure)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil) { [weak self] in
            self?.scrollToBottomIfPinned()
        }
    }

    private func userImages(_ messageId: UUID) -> [UIImage] {
        if let cached = images[messageId] { return cached }
        let loaded = ((try? AppServices.store.messageImages(messageId: messageId)) ?? []).compactMap(UIImage.init(data:))
        images[messageId] = loaded
        return loaded
    }

    private func cellKind(_ message: Message) -> Int {
        if message.kind == .proposal { return 3 }
        if message.kind == .repayment { return 4 }
        return switch (message.role, message.status) {
        case (.user, _): 0
        case (.assistant, .failed): 1
        case (.assistant, _): 2
        }
    }

    private func accept(_ message: Message) {
        var candidate: Candidate?
        if let hint = decodedProposal(message)?.place, let (list, auto) = placeLookupResult(for: message, hint: hint), !list.isEmpty {
            candidate = PlaceMatching.resolvedPlace(explicit: placeOverrides[message.id], auto: auto)
        }
        do {
            try session.accept(message, place: candidate)
        } catch {
            let alert = UIAlertController(title: "记账失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
        }
    }

    private func decodedProposal(_ message: Message) -> ExpenseProposal? {
        guard message.kind == .proposal, let payload = message.payload else { return nil }
        return try? ExpenseProposal.decode(payload)
    }

    private func placeRow(for message: Message, occurredAt: Date) -> ProposalPlaceRow? {
        if message.proposalState == .accepted {
            guard let expenseId = message.expenseId, let place = acceptedPlace(expenseId: expenseId) else { return nil }
            let name = [place.name, place.branch].compactMap { $0 }.joined(separator: " ")
            return .fixed(name: name, subtitle: place.address)
        }
        guard let hint = decodedProposal(message)?.place else { return nil }
        startPlaceSearchIfNeeded(message: message, hint: hint, occurredAt: occurredAt)
        guard let (list, auto) = placeLookupResult(for: message, hint: hint) else { return .searching }
        if list.isEmpty { return .unresolved }
        let selected = PlaceMatching.resolvedPlace(explicit: placeOverrides[message.id], auto: auto)
        if auto != nil { return .auto(candidates: list, selected: selected) }
        return .multiple(hintName: hint.name, candidates: list, selected: selected)
    }

    private func placeLookupResult(for message: Message, hint: PlaceHint) -> (list: [Candidate], auto: Candidate?)? {
        guard case .candidates(let list) = placeLookups[message.id] else { return nil }
        guard !list.isEmpty else { return (list, nil) }
        let hintPhone = hint.phone.map(PlaceMatching.normalizePhone)
        let phoneHit = hintPhone != nil && list[0].phone.map(PlaceMatching.normalizePhone) == hintPhone
        return (list, (list.count == 1 || phoneHit) ? list[0] : nil)
    }

    private func selectPlace(_ candidate: Candidate?, for message: Message) {
        placeOverrides[message.id] = candidate.map(ProposalPlaceChoice.candidate) ?? .declined
        refreshPlaceRow(for: message.id)
    }

    private func startPlaceSearchIfNeeded(message: Message, hint: PlaceHint, occurredAt: Date) {
        guard placeLookups[message.id] == nil else { return }
        placeLookups[message.id] = .searching
        let ledgerId = session.ledger.id
        Task { [weak self] in
            let results = await PlaceSearch.search(hint: hint, ledgerId: ledgerId, occurredAt: occurredAt)
            guard let self else { return }
            placeLookups[message.id] = .candidates(results)
            refreshPlaceRow(for: message.id)
        }
    }

    private func refreshPlaceRow(for messageId: UUID) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(messageId) != nil else { return }
        snapshot.reconfigureItems([messageId])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func acceptedPlace(expenseId: UUID) -> Place? {
        try? AppServices.store.writer.read { db in
            guard let expense = try Expense.fetchOne(db, key: expenseId.uuidString), let placeId = expense.placeId else { return nil }
            return try Place.fetchOne(db, key: placeId.uuidString)
        }
    }

    private func openExpense(_ expenseId: UUID?) {
        guard let expenseId else { return }
        let store = AppServices.store
        let me = try? store.writer.read { db in
            try Member.filter(Column("ledgerId") == session.ledger.id.uuidString && Column("actorId") == store.actorId.uuidString).fetchOne(db)?.participantId
        }
        navigationController?.pushViewController(ExpenseDetailViewController(expenseId: expenseId, myParticipantId: me), animated: true)
    }

    private func relayoutStreamingCell() {
        DispatchQueue.main.async { [self] in
            UIView.performWithoutAnimation {
                collectionView.collectionViewLayout.invalidateLayout()
                collectionView.layoutIfNeeded()
                scrollToBottomIfPinned()
            }
        }
    }

    private func scrollToBottomIfPinned() {
        guard pinnedToBottom, let last = dataSource.snapshot().itemIdentifiers.last, let indexPath = dataSource.indexPath(for: last) else { return }
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: false)
    }

    private func refreshProviderState() {
        let settings = AgentSettings.load()
        let configured = settings.isConfigured
        composer.notice = configured ? nil : "未配置 AI 服务，点击设置"
        composer.modelTitle = settings.model
        composer.isEnabled = configured
    }
}

extension ChatViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        let distance = scrollView.contentSize.height - scrollView.bounds.height - scrollView.contentOffset.y + scrollView.adjustedContentInset.bottom
        pinnedToBottom = distance < scrollView.bounds.height
    }
}
