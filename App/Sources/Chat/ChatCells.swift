import ChatKitCore
import LedgerPersistence
import MarkdownParser
import MarkdownView
import SwiftUI
import UIKit

struct UserBubbleView: View {
    var text: String
    var images: [UIImage] = []

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(images.indices, id: \.self) { index in
                    Image(uiImage: images[index])
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityLabel("照片")
                }
                if !text.isEmpty {
                    Text(text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct FailedMessageView: View {
    var text: String
    var error: String
    var onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !text.isEmpty {
                Text(text)
            }
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(error)
                    .lineLimit(3)
                Spacer()
                Button("重试", action: onRetry)
                    .buttonStyle(.bordered)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

final class AssistantMessageCell: UICollectionViewCell {
    private let textView = MarkdownTextView()
    private var reveal = CKTextReveal()
    private var renderedText: String?
    private var displayLink: CADisplayLink?
    private var lastHeight: CGFloat = 0
    private let insets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
    var onHeightChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.theme = ChatMarkdownTheme.assistant
        contentView.addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(text: String, streaming: Bool) {
        if streaming {
            reveal.receive(text, animate: true, at: CACurrentMediaTime())
            startTicking()
        } else {
            reveal.receive(text, animate: false, at: CACurrentMediaTime())
            stopTicking()
            render(notify: false)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopTicking()
        reveal = CKTextReveal()
        renderedText = nil
        textView.reset()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = contentView.bounds.inset(by: insets)
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        attributes.size.height = height(forWidth: layoutAttributes.size.width)
        return attributes
    }

    private func height(forWidth width: CGFloat) -> CGFloat {
        let fitted = textView.boundingSize(for: width - insets.left - insets.right)
        return max(fitted.height, 22) + insets.top + insets.bottom
    }

    private func startTicking() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        reveal.advance(at: CACurrentMediaTime())
        render()
        if !reveal.hasPending { stopTicking() }
    }

    private func render(notify: Bool = true) {
        if renderedText != reveal.shown {
            renderedText = reveal.shown
            textView.setContentImmediately(MarkdownContent(parserResult: MarkdownParser().parse(reveal.shown), theme: ChatMarkdownTheme.assistant))
        }
        let height = height(forWidth: bounds.width)
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
            if notify { onHeightChange?() }
        }
    }
}
