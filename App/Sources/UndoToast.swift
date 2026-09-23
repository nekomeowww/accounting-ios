import UIKit

enum UndoToast {
    @MainActor
    static func show(in container: UIView, message: String, undo: @escaping () throws -> Void) {
        container.subviews.filter { $0.accessibilityIdentifier == "undo-toast" }.forEach { $0.removeFromSuperview() }
        var config = UIButton.Configuration.glass()
        config.title = "撤销"
        config.cornerStyle = .capsule
        let button = UIButton(configuration: config)
        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.spacing = 12
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 8)
        let toast = UIVisualEffectView(effect: UIGlassEffect())
        toast.accessibilityIdentifier = "undo-toast"
        toast.cornerConfiguration = .capsule()
        toast.contentView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        toast.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toast)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: toast.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: toast.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: toast.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: toast.contentView.trailingAnchor),
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            toast.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -76),
        ])
        button.addAction(UIAction { [weak toast] _ in
            toast?.removeFromSuperview()
            try? undo()
        }, for: .primaryActionTriggered)
        UIAccessibility.post(notification: .announcement, argument: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak toast] in
            UIView.animate(withDuration: 0.25, animations: { toast?.alpha = 0 }) { _ in toast?.removeFromSuperview() }
        }
    }
}
