# UIKit 记账应用的 Local First 与协同选型

调研日期：2026-09-22。状态：背景研究，尚未通过真机与跨端原型验证。

决策更新：用户已确定当前只做本地持久化与本地计算，CRDT 和同步实验之后再看。下文保留当时的研究建议，其中“数据模型定稿前做同步原型”不再作为当前工作要求；以技术 Spec 和 todo 为准。

已知约束：UIKit、iOS 26+、iPhone only；V1 单设备与多个本地成员；未来覆盖 Web + Apple 平台。本文把库作者文档、源码和发布记录作为事实来源；架构取舍明确标为建议。

## 建议先分开两个决定

**建议：V1 以 GRDB/SQLite 保存本地账本；正式定稿数据模型前，做一个很小的 Swift ↔ Web 同步原型，优先验证 Automerge，Loro 作为另一候选。** 不需要为了预留同步而在 V1 上线账号、服务器或实时协作，但不能承诺以后“加一个 adapter 就完成协同”。CRDT 的聚合边界、并发修改语义和迁移协议需要提前证明。

UIKit 负责呈现与输入，数据库负责持久化与查询，CRDT 负责不同副本的合并。它们是不同层。UIKit 采用哪一种控件，不会直接决定要用 Yjs、Automerge 还是 Loro。建议 UI 读取稳定的查询结果，表单与 AI 都提交相同的 Domain Action；不让视图直接改 CRDT 容器。

## 本地持久化

| 方案 | 已核实能力 | 本项目判断 |
| --- | --- | --- |
| GRDB + SQLite | SQL、事务、数据库观察；`ValueObservation` 可以根据查询数据变化发布结果。支持 Swift Package Manager。 | **首选建议**。账本、成员、分摊、结算、地图筛选和操作日志适合关系查询；事务边界、迁移和调试明确。同步需另外设计。 |
| Core Data | 对象图持久化，`NSFetchedResultsController` 可向 UIKit 提供查询变化；Apple 提供基于 CloudKit 的跨用户共享方案。 | 合理备选，尤其团队熟悉 Core Data 或产品只做 Apple 时。未来 Web + Apple 的共享协议仍需单独实现。 |
| SwiftData | `ModelContainer`/`ModelContext` 可显式 fetch/save；Apple 明确提供非 SwiftUI 环境的 fetch 用法。 | **能用于 UIKit**，不能因为 UIKit 就说不兼容；但本项目不依赖其 SwiftUI 查询绑定，复杂查询、显式 SQL 与跨平台同步策略使 GRDB 更符合目前需求。 |

来源：[GRDB 官方仓库](https://github.com/groue/GRDB.swift)、[GRDB ValueObservation](https://swiftpackageindex.com/groue/GRDB.swift/documentation/grdb/valueobservation)、[Core Data 查询控制器](https://developer.apple.com/documentation/coredata/nsfetchedresultscontroller)、[Core Data 共享](https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users)、[SwiftData 持久化与非 SwiftUI 查询](https://developer.apple.com/documentation/swiftdata/preserving-your-apps-model-data-across-launches)、[ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext)。

## CRDT 横向比较

| 方案 | Swift / Apple 的实际情况 | 与记账有关的特点 | 判断 |
| --- | --- | --- | --- |
| Automerge | 官方 `automerge-swift`，Rust 内核经 UniFFI 与 XCFramework 分发，Swift Package 可用。另有 `automerge-repo-swift` 提供可插拔存储和网络。 | 同一个属性的并发值可以被保留并读取；Swift `Document.getAll(obj:key:)` 已暴露此能力，适合显示“这笔金额存在两个版本”。 | **优先做跨端原型**。可检查冲突对账本有价值，但不等于金融业务规则自动成立。Core 与 Repo 的成熟度、Swift 6 并发和 JS 版本兼容需要分别验证。 |
| Loro | 官方组织维护 `loro-swift`，同样采用 Rust/UniFFI/XCFramework；README 仍明确标注 experimental。 | Map 使用 Lamport 逻辑时钟的 LWW；支持 Text、List、MovableList、Tree、Counter、历史 checkout、增量导入导出和局部 UndoManager。Swift 源码可见 UndoManager callback 包装。 | **值得一起验证**。可以把它理解为有历史与版本能力的通用 CRDT 文档引擎；移动列表、树和富文本是优势，但账本未必需要。Swift 绑定的 experimental 状态不能由内核版本号抵消。 |
| Yjs / Yrs / YSwift | Yjs 是 JS 库；原生 Swift 路线是 Yrs 的 `y-crdt/yswift`，Yjs 官方列出的语言绑定。README 明确 WIP，部分 Yrs/Yjs 能力尚未暴露。 | Web 编辑器与 provider 生态丰富；YSwift 已有原生 `YUndoManager`，不能说 Swift 完全不支持撤销。网络 provider 的 JS 生态不能直接当作原生 Swift SDK。 | 本项目不是富文本编辑器，**不作为默认首选**。若未来 Web 已深度使用 Yjs，可重新提高优先级；否则会承担更多原生桥接与兼容验证成本。 |

来源：[Automerge Swift](https://github.com/automerge/automerge-swift)、[Swift Document 源码](https://github.com/automerge/automerge-swift/blob/main/Sources/Automerge/Document.swift)、[Automerge 冲突语义](https://automerge.org/docs/reference/documents/conflicts/)、[Automerge Repo Swift](https://github.com/automerge/automerge-repo-swift)、[Loro Swift](https://github.com/loro-dev/loro-swift)、[Loro Map](https://www.loro.dev/docs/tutorial/map)、[Loro Undo](https://www.loro.dev/docs/advanced/undo)、[Loro Swift Undo 包装](https://github.com/loro-dev/loro-swift/blob/main/Sources/Loro/Loro.swift)、[Yjs 语言绑定](https://github.com/yjs/yjs#ports)、[YSwift](https://github.com/y-crdt/yswift)、[YSwift UndoManager](https://github.com/y-crdt/yswift/blob/main/Sources/YSwift/YUndoManager.swift)。

### 发布状态核验

以下是调研时 GitHub Releases API 返回的最新 release，不表示已在本项目验证，也不应直接作为依赖锁定决定。

| 包 | 最新 release | 发布时间（UTC） |
| --- | --- | --- |
| Automerge Swift | 0.7.2 | 2025-12-20 |
| Automerge Repo Swift | 0.3.2 | 2024-11-01 |
| Loro Swift | 1.16.2 | 2026-09-21 |
| YSwift | 0.2.1 | 2024-04-04 |

来源：[Automerge Swift release](https://github.com/automerge/automerge-swift/releases/tag/0.7.2)、[Repo Swift release](https://github.com/automerge/automerge-repo-swift/releases/tag/0.3.2)、[Loro Swift release](https://github.com/loro-dev/loro-swift/releases/tag/1.16.2)、[YSwift release](https://github.com/y-crdt/yswift/releases/tag/0.2.1)。特别注意：Repo Swift README 仍写着尚无 release，这与真实发布记录矛盾，属于过时文字；不能据此宣称它没有 release。发布频率本身也不能证明可靠性。

## 记账不能只依赖 CRDT 收敛

**设计推论：副本最终相同，不代表账在业务上正确。** 例如 A 离线把总额从 100 改成 120 并重新均分，B 离线把成员从两人改成三人。字段级合并可能产生一个双方都没有提交过的“总额 + 分摊”组合。Automerge 保留同字段并发值、Loro Map 选择确定性赢家，都不能自动维持跨字段与跨记录约束。[Automerge 属性冲突](https://automerge.org/docs/reference/documents/conflicts/)、[Loro Map 语义](https://www.loro.dev/docs/tutorial/map)。

建议技术 Spec 明确以下规则：

1. **金额、币种、付款人和分摊作为一个账单修订验证。** 整数最小货币单位保存金额；不要用浮点数累计余额。Exact 分摊之和必须等于总额，均分余数按固定成员顺序分配。相同输入的 Swift 与 Web 结果必须一致。
2. **余额与欠款建议从有效账单和结算事件推导。** 不直接把每个人的余额建成可随意累加的 CRDT Counter；修改账单可能涉及冲销与重新分配。
3. **财务关键并发修改显式处理。** 可采用不可变 ExpenseRevision 和父版本关系，保留两条竞争修订，用户选择后写入 Resolution。具体表示方式由原型决定；别用设备墙上时间静默覆盖金额。
4. **Action 有稳定 ID、版本和幂等语义。** 本地业务写入与操作日志在同一个数据库事务提交。V1 的日志用于审计和撤销；不宣称它已经是完整可重放、可分布式归并的事件源。
5. **撤销是业务操作。** 撤销一次 AI“新增账单并分摊”应整体处理；已有后续修改时不能盲目恢复整份旧快照。协同时优先补偿 Action / 新修订并检查前置版本。文本编辑 UndoManager 与此不同。
6. **删除、恢复与移除成员需独立规则。** Tombstone、已被他人修改的记录、成员仍被历史账单引用、重复上传结算，都需定义确定行为。

Loro 的 commit 用于变更分组和事件批处理，官方特别说明它不提供 ACID 事务的回滚与隔离；因此 CRDT commit 不能替代本地持久化事务。[Loro API 的事务说明](https://www.loro.dev/docs/api/js)。

## 服务器与替代路线

**事实：CRDT 核心不等于完整协作服务。** Automerge Repo 可以提供存储与网络拼装；Yjs 明确把数据结构、网络和持久化分层；Loro 提供可传输的增量，应用仍要选择如何发送、保存与授权。[Automerge Repo Swift](https://github.com/automerge/automerge-repo-swift)、[Yjs 分层](https://yjs.dev/)、[Loro 导入导出示例](https://github.com/loro-dev/loro-swift)。

**设计推论：** V2 仍需要身份、账本访问权限、邀请、同步服务/中继、持久化、断线重试、版本兼容以及附件上传下载。收据图片宜独立作为文件或对象存储，文档中只同步引用与校验信息。撤回成员访问和离线副本的关系也需要产品定义。

- **CKSyncEngine / CloudKit**：可以对自定义本地存储做同步，支持 private 和 shared database；应用负责保存引擎状态以及处理业务冲突，自动同步时机不确定。对 Apple-only 很有吸引力。**建议**：未来已确认 Web + Apple，因此不选作共同主同步层；这不是宣称 CloudKit 没有 Web 能力。[CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-4b4w9)、[Apple 同步讲解](https://developer.apple.com/videos/play/wwdc2023/10188/)。
- **PowerSync + 后端数据库**：官方有 Swift SDK、SQLite 本地读写与查询订阅，也有 GRDB 接口路线；上传需要实现 `uploadData`，由应用后端处理写入。**建议**：若希望服务器裁决账单修改、偏关系模型，可作为 CRDT 的实质替代方案。代价是服务端与同步服务的运维/依赖，以及离线写入被拒绝时的产品体验。普通 GRDB 数据库不应假设可零迁移切换。[PowerSync Swift SDK](https://docs.powersync.com/client-sdks/reference/swift)。

## 进入技术 Spec 前的小原型

建议只选一个最小账本，用 Swift 与浏览器两端验证 Automerge 与 Loro，时间限制到数日，输出可重复结果，而不是直接展开完整同步架构。

- 同一笔账单的总额、分摊与删除/恢复并发修改；乱序、重复传输与离线重连。
- 一端本地撤销后另一端编辑仍保留；AI Action 重试不重复入账。
- 保存、强制退出、恢复与再次同步；Swift 与 Web 金额和余数完全一致。
- 原生 iPhone/iOS 26 + Swift 6 构建，JS ↔ Swift 文档格式互通；FFI 回调线程、取消、生命周期与包体积。
- 1,000 / 10,000 笔账单下的载入、合并、内存和存储增长；以同一数据集比较，不能只引用库自己的宣传 benchmark。

尚未验证：上述候选的当前 release 在项目工具链中的编译结果、跨端协议兼容、真实负载表现、历史压缩与长期数据迁移。若最终选择 CRDT，需写清它与 SQLite 的唯一写入路径及崩溃恢复：例如持久化 CRDT 更新与读取投影的协调方式，不能让两者各自成为权威来源。
