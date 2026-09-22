import UIKit

enum ChatComposerActionMode {
    case send, loading, stop

    var color: UIColor {
        switch self {
        case .send: .tintColor
        case .loading: .systemGray
        case .stop: .systemRed
        }
    }

    var symbolName: String {
        switch self {
        case .send, .loading: "arrow.up"
        case .stop: "stop.fill"
        }
    }
}

private final class ChatComposerProgressView: UIView {
    private let arc = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        arc.fillColor = UIColor.clear.cgColor
        arc.strokeColor = UIColor.white.cgColor
        arc.lineCap = .round
        arc.lineWidth = 2.25
        layer.addSublayer(arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        arc.frame = bounds
        let inset = arc.lineWidth / 2
        arc.path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: max(0, min(bounds.width, bounds.height) / 2 - inset),
            startAngle: -.pi / 2, endAngle: .pi, clockwise: true
        ).cgPath
    }

    func startAnimating() {
        isHidden = false
        guard layer.animation(forKey: "rotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 0.8
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(rotation, forKey: "rotation")
    }

    func stopAnimating() {
        isHidden = true
        layer.removeAnimation(forKey: "rotation")
    }
}

final class ChatComposerActionVisual: UIView {
    private let content = UIView()
    private let symbol = UIImageView()
    private let progress = ChatComposerProgressView()
    private var mode: ChatComposerActionMode?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerCurve = .continuous
        symbol.contentMode = .center
        symbol.tintColor = .white
        addSubview(content)
        content.addSubview(symbol)
        content.addSubview(progress)
        for view in [content, symbol, progress] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            symbol.topAnchor.constraint(equalTo: content.topAnchor),
            symbol.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            symbol.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            symbol.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progress.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 15),
            progress.heightAnchor.constraint(equalToConstant: 15),
        ])
        render(.send)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
    }

    func render(_ nextMode: ChatComposerActionMode) {
        guard mode != nextMode else { return }
        let shouldAnimate = mode != nil && window != nil
        mode = nextMode
        guard shouldAnimate else {
            backgroundColor = nextMode.color
            applyContent(nextMode)
            return
        }
        let duration = UIAccessibility.isReduceMotionEnabled ? 0.18 : 0.2
        UIView.transition(with: content, duration: duration, options: [.transitionCrossDissolve, .beginFromCurrentState, .allowAnimatedContent]) {
            self.applyContent(nextMode)
        }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.backgroundColor = nextMode.color
        }
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animateKeyframes(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.45) {
                self.content.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.55) {
                self.content.transform = .identity
            }
        }
    }

    private func applyContent(_ mode: ChatComposerActionMode) {
        symbol.image = UIImage(systemName: mode.symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold, scale: .medium))
        symbol.isHidden = mode == .loading
        if mode == .loading { progress.startAnimating() } else { progress.stopAnimating() }
    }
}
