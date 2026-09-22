# Accounting iOS

AI 协同记账 / AA 分账 App。正式产品名待定。

已确定：UIKit、iOS 26.0+、iPhone only、遵循 Apple HIG、Local First。
未来协同面向 Web + Apple；开发阶段使用用户自己的 AI API Key。
当前优先本地持久化与本地计算；V1 支持本地 Export As / Save As；CRDT、持续同步和业务服务器后置。

工程结构：UIKit 负责 App 入口、Scene 与导航；单个页面用 SwiftUI 声明并由 `UIHostingController` 承载。

## 构建

```bash
brew install xcodegen
xcodegen generate
open Accounting.xcodeproj
```

`Accounting.xcodeproj` 由 `project.yml` 生成，不入库；改动工程配置改 `project.yml` 后重新生成。
命令行：

```bash
xcodebuild -project Accounting.xcodeproj -scheme Accounting -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project Accounting.xcodeproj -scheme Accounting -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

- `App/`：App target（`dev.innei.Accounting`，iOS 26.0+，iPhone only，Swift 6）
- `Packages/LedgerKit/`：本地 Swift Package，当前只有 `LedgerDomain`

- [产品 Spec v0.2](docs/product/product-spec-v0.2.md)
- [技术 Spec v0.1 讨论稿](docs/technical/technical-spec-v0.1.md)
- [本地数据模型 Spec](docs/superpowers/specs/2026-09-23-local-schema-design.md)
- [小票凭证数据模型建议](docs/technical/receipt-data-model.md)
- [分阶段 todo](docs/technical/todo.md)
- [Local First 选型研究](docs/research/local-first-ios.md)
- [开源 Expense 项目与表结构研究](docs/research/expense-schema-comparison.md)

技术讨论稿中的建议不代表已确认的技术决策。
