import UIKit

final class ChatComposerView: UIView, UITextViewDelegate {
    private static let maximumInputHeight: CGFloat = 140
    private let container = UIVisualEffectView(effect: nil)
    private let inputSurface = UIVisualEffectView(effect: nil)
    private let attachSurface = UIVisualEffectView(effect: nil)
    private let input = UITextView()
    private let hint = UILabel()
    private let noticeButton = UIButton(type: .system)
    private let send = UIButton(type: .system)
    private let sendVisual = ChatComposerActionVisual()
    private let sendFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let attach = UIButton(type: .system)
    private let attachGlyph = UIImageView()
    private let accessoryBar = UIView()
    private let modelButton = UIButton(type: .system)
    private var inputHeight: NSLayoutConstraint!
    private var accessoryHeight: NSLayoutConstraint!
    private var hintTop: NSLayoutConstraint!
    private var noticeHeight: NSLayoutConstraint!
    private var separateLayout: [NSLayoutConstraint] = []
    private var focusedLayout: [NSLayoutConstraint] = []
    private var attachPlacement: [NSLayoutConstraint] = []
    private var expanded = false
    private var measuredWidth: CGFloat = 0

    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onNoticeTap: (() -> Void)?
    var onModelTap: (() -> Void)?
    var onHeightChange: (() -> Void)?

    var isStreaming = false { didSet { update() } }
    var isEnabled = true { didSet { update() } }
    var notice: String? { didSet { update() } }
    var modelTitle = "" { didSet { update() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let containerEffect = UIGlassContainerEffect()
        containerEffect.spacing = 8
        container.effect = containerEffect
        for surface in [inputSurface, attachSurface] {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            surface.effect = glass
        }
        inputSurface.cornerConfiguration = .capsule(maximumRadius: 26)
        attachSurface.cornerConfiguration = .capsule()

        input.backgroundColor = .clear
        input.font = .systemFont(ofSize: 17)
        input.textColor = .label
        input.autocorrectionType = .no
        input.delegate = self
        hint.text = "Ask Agent…"
        hint.font = input.font
        hint.textColor = .placeholderText
        hint.isUserInteractionEnabled = false

        attach.tintColor = .label
        attach.showsMenuAsPrimaryAction = true
        attach.menu = UIMenu(children: [
            UIAction(title: "拍照", image: UIImage(systemName: "camera"), attributes: .disabled) { _ in },
            UIAction(title: "照片图库", image: UIImage(systemName: "photo.on.rectangle.angled"), attributes: .disabled) { _ in },
        ])
        attachGlyph.image = Self.plusImage(pointSize: 17)
        attachGlyph.tintColor = .label
        attachGlyph.contentMode = .center
        attachGlyph.isUserInteractionEnabled = false
        attach.addSubview(attachGlyph)

        sendVisual.translatesAutoresizingMaskIntoConstraints = false
        send.addSubview(sendVisual)
        send.addAction(UIAction { [weak self] _ in self?.submit() }, for: .primaryActionTriggered)

        var modelConfig = UIButton.Configuration.plain()
        modelConfig.imagePlacement = .trailing
        modelConfig.imagePadding = 4
        modelConfig.baseForegroundColor = .label
        modelConfig.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        modelButton.configuration = modelConfig
        modelButton.addAction(UIAction { [weak self] _ in self?.onModelTap?() }, for: .primaryActionTriggered)

        noticeButton.titleLabel?.font = .systemFont(ofSize: 13)
        noticeButton.titleLabel?.numberOfLines = 0
        noticeButton.addAction(UIAction { [weak self] _ in self?.onNoticeTap?() }, for: .primaryActionTriggered)

        addSubview(container)
        container.contentView.addSubview(noticeButton)
        container.contentView.addSubview(attachSurface)
        container.contentView.addSubview(inputSurface)
        attachSurface.contentView.addSubview(attach)
        for view in [input, hint, accessoryBar, send] { inputSurface.contentView.addSubview(view) }
        accessoryBar.addSubview(modelButton)
        for view in [container, inputSurface, attachSurface, noticeButton, input, hint, accessoryBar, send, attach, attachGlyph, modelButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        inputHeight = input.heightAnchor.constraint(equalToConstant: 48)
        accessoryHeight = accessoryBar.heightAnchor.constraint(equalToConstant: 0)
        hintTop = hint.topAnchor.constraint(equalTo: input.topAnchor, constant: 13)
        noticeHeight = noticeButton.heightAnchor.constraint(equalToConstant: 0)
        separateLayout = [
            attachSurface.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            inputSurface.leadingAnchor.constraint(equalTo: attachSurface.trailingAnchor, constant: 8),
        ]
        focusedLayout = [
            attachSurface.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            inputSurface.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
        ]
        NSLayoutConstraint.activate(separateLayout + [
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            noticeButton.topAnchor.constraint(equalTo: container.topAnchor),
            noticeButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            noticeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            noticeHeight,
            inputSurface.topAnchor.constraint(equalTo: noticeButton.bottomAnchor, constant: 8),
            inputSurface.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            inputSurface.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            attachSurface.widthAnchor.constraint(equalToConstant: 44),
            attachSurface.heightAnchor.constraint(equalToConstant: 44),
            attachSurface.bottomAnchor.constraint(equalTo: inputSurface.bottomAnchor, constant: -2),
            input.topAnchor.constraint(equalTo: inputSurface.contentView.topAnchor),
            input.leadingAnchor.constraint(equalTo: inputSurface.contentView.leadingAnchor),
            input.trailingAnchor.constraint(equalTo: inputSurface.contentView.trailingAnchor),
            inputHeight,
            accessoryBar.topAnchor.constraint(equalTo: input.bottomAnchor),
            accessoryBar.leadingAnchor.constraint(equalTo: inputSurface.contentView.leadingAnchor),
            accessoryBar.trailingAnchor.constraint(equalTo: inputSurface.contentView.trailingAnchor),
            accessoryBar.bottomAnchor.constraint(equalTo: inputSurface.contentView.bottomAnchor),
            accessoryHeight,
            hint.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 21),
            hintTop,
            hint.trailingAnchor.constraint(lessThanOrEqualTo: send.leadingAnchor),
            send.trailingAnchor.constraint(equalTo: inputSurface.contentView.trailingAnchor, constant: -2),
            send.bottomAnchor.constraint(equalTo: inputSurface.contentView.bottomAnchor, constant: -2),
            send.widthAnchor.constraint(equalToConstant: 44),
            send.heightAnchor.constraint(equalToConstant: 44),
            sendVisual.centerXAnchor.constraint(equalTo: send.centerXAnchor),
            sendVisual.centerYAnchor.constraint(equalTo: send.centerYAnchor),
            sendVisual.widthAnchor.constraint(equalToConstant: 30),
            sendVisual.heightAnchor.constraint(equalToConstant: 30),
            attachGlyph.centerXAnchor.constraint(equalTo: attach.centerXAnchor),
            attachGlyph.centerYAnchor.constraint(equalTo: attach.centerYAnchor),
            modelButton.leadingAnchor.constraint(equalTo: accessoryBar.leadingAnchor, constant: 54),
            modelButton.centerYAnchor.constraint(equalTo: send.centerYAnchor),
            modelButton.heightAnchor.constraint(equalToConstant: 44),
            modelButton.trailingAnchor.constraint(lessThanOrEqualTo: send.leadingAnchor, constant: -2),
        ])
        placeAttach()
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(input.bounds.width - measuredWidth) > 0.5 {
            measuredWidth = input.bounds.width
            update()
        }
    }

    func attachScrollEdge(to scrollView: UIScrollView) {
        scrollView.bottomEdgeEffect.isHidden = false
        scrollView.bottomEdgeEffect.style = .automatic
        let edge = UIScrollEdgeElementContainerInteraction()
        edge.scrollView = scrollView
        edge.edge = .bottom
        addInteraction(edge)
    }

    func clear() {
        input.text = ""
        update()
    }

    func textViewDidChange(_ textView: UITextView) { update() }
    func textViewDidBeginEditing(_ textView: UITextView) { update() }
    func textViewDidEndEditing(_ textView: UITextView) { update() }

    private static func plusImage(pointSize: CGFloat) -> UIImage? {
        UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: pointSize > 15 ? .medium : .regular))
    }

    private func placeAttach() {
        NSLayoutConstraint.deactivate(attachPlacement)
        let host = expanded ? inputSurface.contentView : attachSurface.contentView
        let frame = attach.convert(attach.bounds, to: host)
        host.addSubview(attach)
        if !attach.bounds.isEmpty { attach.frame = frame }
        attachPlacement = [
            attach.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: expanded ? 6 : 0),
            attach.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: expanded ? -2 : 0),
            attach.widthAnchor.constraint(equalToConstant: 44),
            attach.heightAnchor.constraint(equalToConstant: 44),
        ]
        NSLayoutConstraint.activate(attachPlacement)
    }

    private func submit() {
        if isStreaming {
            onStop?()
        } else {
            let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            sendFeedback.impactOccurred()
            onSend?(text)
        }
    }

    private func update() {
        let nowExpanded = input.isFirstResponder
        let expansionChanged = expanded != nowExpanded
        if expansionChanged && window != nil { layoutIfNeeded() }
        expanded = nowExpanded
        if expansionChanged {
            attachSurface.isUserInteractionEnabled = !expanded
            if !expanded { placeAttach() }
            NSLayoutConstraint.deactivate(separateLayout + focusedLayout)
            NSLayoutConstraint.activate(expanded ? focusedLayout : separateLayout)
        }

        input.isEditable = isEnabled
        hint.isHidden = !input.text.isEmpty
        let hasContent = !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.isEnabled = isEnabled && (isStreaming || hasContent)
        if send.isEnabled && !isStreaming { sendFeedback.prepare() }
        sendVisual.render(isStreaming ? .stop : .send)
        sendVisual.alpha = send.isEnabled ? 1 : 0.35

        noticeButton.setTitle(notice, for: .normal)
        noticeButton.setTitleColor(.tintColor, for: .normal)
        let noticeSize = noticeButton.sizeThatFits(CGSize(width: max(1, bounds.width - 40), height: .greatestFiniteMagnitude))
        noticeHeight.constant = (notice ?? "").isEmpty ? 0 : max(44, noticeSize.height + 12)

        modelButton.configuration?.title = modelTitle
        modelButton.isHidden = !expanded || modelTitle.isEmpty
        accessoryHeight.constant = expanded ? 44 : 0
        let verticalInset = expanded ? 13 : max(0, (48 - input.font!.lineHeight) / 2)
        input.textContainerInset = UIEdgeInsets(top: verticalInset, left: 16, bottom: verticalInset, right: expanded ? 16 : 46)
        hintTop.constant = verticalInset
        let height = input.sizeThatFits(CGSize(width: max(1, input.bounds.width), height: .greatestFiniteMagnitude)).height
        inputHeight.constant = min(Self.maximumInputHeight, max(expanded ? 68 : 48, height))
        input.isScrollEnabled = height > Self.maximumInputHeight
        setNeedsLayout()
        onHeightChange?()

        guard expansionChanged else { return }
        if window != nil && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.24, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.layoutIfNeeded()
            } completion: { finished in
                if finished && self.expanded == nowExpanded { self.completeTransition() }
            }
        } else {
            layoutIfNeeded()
            completeTransition()
        }
    }

    private func completeTransition() {
        attachGlyph.image = Self.plusImage(pointSize: expanded ? 14 : 17)
        UIView.performWithoutAnimation {
            if expanded { placeAttach() }
            attach.layoutIfNeeded()
        }
    }
}
