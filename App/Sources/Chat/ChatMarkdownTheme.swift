import MarkdownView
import UIKit

enum ChatMarkdownTheme {
    static let assistant: MarkdownTheme = {
        var theme = MarkdownTheme()
        let body = UIFont.preferredFont(forTextStyle: .body)
        theme.fonts.body = body
        theme.fonts.bold = body.bold
        theme.fonts.italic = body.italic
        theme.fonts.code = .monospacedSystemFont(ofSize: 13, weight: .regular)
        theme.fonts.codeInline = .monospacedSystemFont(ofSize: 14, weight: .regular)
        theme.fonts.title = .systemFont(ofSize: 20, weight: .semibold)
        theme.fonts.largeTitle = .systemFont(ofSize: 23, weight: .semibold)
        theme.fonts.footnote = .preferredFont(forTextStyle: .footnote)
        theme.colors.body = .label
        theme.colors.code = .label
        theme.colors.highlight = .tintColor
        theme.colors.emphasis = .tintColor
        theme.colors.codeBackground = .secondarySystemBackground
        theme.colors.selectionBackground = UIColor.tintColor.withAlphaComponent(0.2)
        theme.spacings.paragraph = 8
        theme.spacings.headingBefore = 12
        theme.spacings.final = 0
        return theme
    }()
}
