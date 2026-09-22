import GRDB
import LedgerDomain
import LedgerPersistence
import SwiftUI
import UIKit

final class ChatViewController: UIViewController {
    private enum Section { case main }

    private let session: ChatSession
    private var messages: [UUID: Message] = [:]
    private var observation: AnyDatabaseCancellable?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, UUID>!
    private let composer = ChatComposerView()
    private var pinnedToBottom = true

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
            guard let self else { return }
            do {
                try session.send(text)
                composer.clear()
                pinnedToBottom = true
            } catch {
                present(UIAlertController(title: "发送失败", message: error.localizedDescription, preferredStyle: .alert), animated: true)
            }
        }
        composer.onStop = { [weak self] in self?.session.stop() }
        composer.onHeightChange = { [weak self] in self?.view.setNeedsLayout() }
        let openSettings: () -> Void = { [weak self] in
            self?.navigationController?.pushViewController(AgentSettingsViewController(), animated: true)
        }
        composer.onNoticeTap = openSettings
        composer.onModelTap = openSettings
    }

    private func configureDataSource() {
        let user = UICollectionView.CellRegistration<UICollectionViewListCell, Message> { cell, _, message in
            cell.contentConfiguration = UIHostingConfiguration { UserBubbleView(text: message.text) }.margins(.vertical, 2)
        }
        let assistant = UICollectionView.CellRegistration<AssistantMessageCell, Message> { [unowned self] cell, _, message in
            let streaming = session.streamingMessageId == message.id
            cell.configure(text: streaming ? session.streamingText : message.text, streaming: streaming)
            cell.onHeightChange = { [weak self] in self?.relayoutStreamingCell() }
        }
        let failed = UICollectionView.CellRegistration<UICollectionViewListCell, Message> { [unowned self] cell, _, message in
            cell.contentConfiguration = UIHostingConfiguration {
                FailedMessageView(text: message.text, error: message.error ?? "失败") { [weak self] in
                    try? self?.session.retry(message)
                }
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [unowned self] collectionView, indexPath, id in
            guard let message = messages[id] else { return UICollectionViewCell() }
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
        session.onStreamingUpdate = { [weak self] id, _ in
            guard let self, let indexPath = dataSource.indexPath(for: id),
                  let cell = collectionView.cellForItem(at: indexPath) as? AssistantMessageCell else { return }
            cell.configure(text: session.streamingText, streaming: true)
        }
        session.onStreamingStateChange = { [weak self] in
            guard let self else { return }
            composer.isStreaming = session.isStreaming
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

    private func cellKind(_ message: Message) -> Int {
        switch (message.role, message.status) {
        case (.user, _): 0
        case (.assistant, .failed): 1
        case (.assistant, _): 2
        }
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
        let configured = settings.makeProvider() != nil
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
