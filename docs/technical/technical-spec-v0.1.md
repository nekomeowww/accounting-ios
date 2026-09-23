# Accounting iOS 技术 Spec v0.1

更新日期：2026-09-23。状态：讨论稿，供逐项决策；尚未进入 App 实现。
产品依据：[Product Spec v0.2](../product/product-spec-v0.2.md)。

阅读顺序：本文是初始讨论基线。已确定并开始实现的账本结构以 [本地数据模型 Spec](../superpowers/specs/2026-09-23-local-schema-design.md) 为准；[小票凭证数据模型](receipt-data-model.md) 提议在其上扩展原始证据、结构化 Receipt 和账目来源映射，仍待评审。

## 1. 已确认约束

- 全部产品视图使用 UIKit。
- 最低部署版本 iOS 26.0；仅 iPhone，目标设备族为 1。
- 设计遵循 Apple HIG，以系统组件、系统交互为基础。
- V1 单设备、多本地成员，无账号和业务云同步也能运行。
- 当前只建设本地持久化与本地计算；CRDT、同步实验与服务器建设全部后置，不阻塞数据模型和 V1。
- 分摊、余额、债务展示、校验、Undo 和统计由设备上的确定性代码完成，业务计算不依赖 server。
- 未来协作覆盖 Web + Apple，同步与账号不以 iCloud 为前提。
- 开发阶段自带 AI API Key，先跑通产品闭环。
- Map、结构化 Items、自然语言修改和 Undo 属于 V1。
- V1 支持 Export As / Save As，由本地账本数据生成 XLSX 文件。

本机工具链已检查：Xcode 26.6、Swift 6.3.3。Swift 语言模式建议采用 Swift 6；具体依赖版本在工程初始化时锁定。

## 2. 建议方案（待讨论确认）

| 领域 | 建议 | 原因 |
| --- | --- | --- |
| UI | UIKit + Auto Layout + 系统导航 / Sheet | 满足平台与 HIG 约束 |
| 页面状态 | 轻量 Screen Model + Observation | 只保存展示状态与输入状态 |
| 导航 | 小型 Coordinator | 集中处理 push、sheet 和账本切换 |
| 业务模型 | 纯 Swift 值类型与 Domain Commands | 表单与 Agent 共用校验和写入边界 |
| 本地存储 | SQLite + GRDB | 显式事务、约束、迁移与查询观察 |
| AI | URLSession + 可替换 provider adapter | 开发者 Key 接入；避免绑定单一供应商 |
| 票据 | 本地文件 + DB metadata | 输入先落盘，失败可恢复 |
| 地图 | MapKit / MKMapView | 展示本地 Expense + Place |
| 文件导出 / 另存为 | 本地 XLSX Export Service + 系统分享 / 文件选择器 | 复用相同文件生成流程，选择分享或保存位置 |
| 未来持续协同 | 之后再选传输与合并方案 | 不引入同步依赖 |

当前按本地持久化推进，SQLite + GRDB 仍为建议实现。UUID、版本、Action Log 服务于稳定引用、编辑校验、审计和撤销，也为未来分享保留空间；它们不是完整同步协议。
CRDT 研究仅作背景资料，之后根据实际分享需求重新评估，不在当前阶段做相关实验。未来引入同步仍可能需要数据迁移。
背景资料见 [Local First 研究](../research/local-first-ios.md)，其中此前建议的前置同步实验已后置。

## 3. 数据流与职责

```text
UIKit → Screen Model → Domain Commands → Local Store → SQLite
                            ↑                  ↓
Input → Durable Job → Agent Proposal      Query Observation
                            ↓                  ↓
                     Domain Validation    Screen State → UIKit
```

Domain 不依赖 UIKit、GRDB 或某个 LLM SDK。Local Store 在同一个事务内提交业务实体、Action 与任务结果。
不要为每个实体创建空转的 Repository / UseCase；先围绕完整操作定义边界。

Ledger Engine 是本地纯 Swift 计算模块：输入有效账目与分摊事实，输出余额、债务和汇总。结果可重建，不需要请求业务服务器。
AI 负责理解输入、提出操作；账是否成立以及结果是多少，由本地引擎决定。开发阶段设备使用 BYOK 直接调用 AI provider。
AI、地点查询和地图底图仍可能联网；这些服务不可用时，已有账本的读取、编辑、分账与撤销必须完整可用。

初始建议一个 App target 加一个本地 Swift Package。Package 内区分 LedgerDomain 与 LedgerPersistence；AI、Assets、Places 先按目录隔离，有明确复用需求后再拆 target。

UI 与 Screen Model 在 MainActor；磁盘访问、图像处理、网络请求不阻塞主线程。数据库负责串行写事务。
网络请求期间不持有写事务；响应回来后重新读取实体版本再提交。

本地查询订阅驱动页面更新。列表使用 UICollectionView 列表布局和 diffable data source，稳定 UUID 作为 item identity。
轻量界面属性可使用 Observation；UIKit 支持在 updateProperties 中自动追踪读取，工程初始化时按官方文档启用并验证。
来源：[UIKit Observation](https://developer.apple.com/documentation/uikit/updating-views-automatically-with-observation-tracking-in-uikit)。

## 4. UIKit 与 HIG

初始页面结构：账本列表 → 当前账本 → Expense Detail。

- 当前账本顶部显示余额摘要；Activity / Map 用 UISegmentedControl 切换同一账本的视图。
- Activity 显示 Expense、待处理输入和必要的 Agent 回执。
- 底部持续提供输入栏与相机 / 图片入口；相机完成后的确认次数需要真机测量。
- Expense Detail 用系统分组列表和编辑 Sheet 承载人工纠正。
- Map Pin 打开简短预览，再进入相同的 Expense Detail。
- 系统字体、Dynamic Type、语义颜色、SF Symbols、VoiceOver、深浅色、Reduce Motion 都纳入验收。
- 优先使用系统导航栏、按钮、菜单与 Sheet；玻璃材质用于交互层，账目内容保持可读性。

iOS 26 标准 UIKit 控件提供新的系统外观；采用系统组件可以直接受益，但 HIG 仍需要逐屏验证。
来源：[Apple HIG](https://developer.apple.com/design/human-interface-guidelines)、[UIKit 新设计](https://developer.apple.com/videos/play/wwdc2025/284/)。

## 5. 金额与账本不变量

以下是建议的工程规则，需要在领域模型阶段固化测试。

1. 金额使用 Int64 最小货币单位 + currency code + exponent，禁止用 Double 表示金额。JPY 与带小数货币不能共用固定两位假设。
2. 对未来 Web JSON，Int64 金额使用十进制字符串传输，避免 JavaScript Number 的精度限制。
3. 总额、付款人、参与者、具体份额视为一个财务一致性边界；所有变化必须一起校验。
4. 每笔 Expense 的份额之和严格等于总额；成员唯一且属于该账本。已被历史账目引用的成员只能归档。
5. 均分采用确定性余数分配：按固定成员 UUID 顺序分配最小单位余数，并持久化最终份额；不同端得到同一结果。
6. 余额按 currency 独立计算：paid - owed；所有成员净余额之和为零。Balance 为派生结果，可重建。
7. V1 暂建议每个账本单一币种；遇到异币保留输入并要求明确处理，不静默换汇。多币种属于待确认范围。
8. “个人消费”分配给明确的消费人；“我请客”将全部份额分配给付款人，同时保留实际参与者，债务为零。
9. 小票 subtotal/tax/tip/serviceCharge/discount 保留提取结果；无法确定含税语义时不强行重复相加。总额可信时可记账并标记明细待核对。
10. 单笔先支持一个付款人；退款、多人垫付、结算记录的行为需另行定界。

净余额与“谁欠谁”不是同一个问题。建议默认保留每笔消费产生的直接债务，展示时可做双方抵消；跨成员债务简化另行确认。

## 6. 持久化模型

本节保留初始候选模型；实际 `participant / member`、逐行分摊与 journal 已在本地数据模型 Spec 中细化。Receipt 表、字段和与账本的关系请参阅 [小票凭证数据模型](receipt-data-model.md)，其中完整 Receipt 保存与当前有效账务分层。

建议核心表：Ledger、Member、Expense、ExpenseParticipant、ExpenseAllocation、ExpenseItem、ItemParticipant、Receipt、Place、Action。
任务相关表：Input、ProcessingJob；对话消息只作为上下文，不能作为账本事实。

核心业务实体使用 UUID；保留 createdAt、updatedAt、deletedAt、version、createdBy、updatedBy。
ActorID 与 MemberID 分开：记录操作的人 / 安装实例，与承担消费的账本成员不是同一个概念。
设备时间只能用于展示与辅助诊断，不能作为未来并发的唯一顺序依据。

Member 是账本内的成员身份；未来可关联账号身份，但账目始终引用稳定 MemberID。当前设备“我是哪个成员”单独作为本地偏好保存，不将 isCurrentUser 当作所有设备共享的成员属性。
version 当前仅用于本地过期写入检测，不作为跨设备因果版本。暂不引入 vector clock、remoteVersion、同步队列或服务端权限表。
业务实体、设备偏好、处理任务与凭据分别存放；未来分享账本时可以明确选择业务数据，不会自动携带 API Key、处理日志或整个设备状态。

Expense 与 Items / Participants / Allocations 以一个聚合提交。Place 解析可在后续独立操作中关联。
Receipt 的模型版本、原始响应、规范化结果与字段证据分开保留；任务重跑不能静默改写已确认 Expense。

Action 建议字段：id、ledgerId、actorId、commandId、type、entityId、expectedVersion、before、after、schemaVersion、createdAt、undoOfActionId。
commandId 在数据库设唯一约束，保证同一命令重试不重复记账。before/after 只覆盖该操作负责的变更范围。

删除为 tombstone。Action 保留审计历史；Undo 写入补偿 Action，不删除原始 Action。
撤销前检查相关字段 / 版本是否仍匹配，避免覆盖后来修改。V1 可先限制为最近一次可撤销业务操作；独立 Place 补全不能使金额修改不可撤销。

数据库 schema version 与实体 version 分开。迁移必须使用上一版 fixture 验证；备份策略需要同时覆盖数据库与原始票据。
Receipt 使用稳定 asset ID 与本地相对路径，Expense 不保存设备专属绝对路径；未来导出可以重新映射资源位置。

## 7. 可靠的输入与 Agent 管线

```text
捕获 / 导入 → 持久化输入与资源 → queued → processing
                                          ├→ needsClarification
                                          ├→ failed → retry
                                          └→ applied → 异步 Place Resolution
```

先写临时文件、完成原子重命名，再创建引用该文件的数据库记录；启动时清理孤立临时文件并恢复中断任务。
持久化 job ID、input ID、attempt、状态、错误与 result command ID。进程中断后将遗留 processing 恢复为可重试状态。
先恢复本地页面，再按需恢复网络任务；不承诺 iOS 在后台持续运行 AI。

Agent 输出类型化 Proposal。Domain 校验金额、成员、份额、账本、目标 Expense 与预期版本，再原子写入。
字段 confidence 只是信号，不作为经过校准的正确率；同时依据证据完整度、金额校验和目标唯一性决定执行或追问。
“刚才那笔”解析出多候选时必须追问。Receipt 文本仅作为待提取数据，不能作为修改其他账目的工具指令。

开发阶段 Key 存 Keychain，不写入 repo、数据库、日志或共享账本；设置页可配置 provider / model。
第一个 provider 与模型尚未选择。先定义很小的结构化提取 / action proposal 接口，再根据实际供应商能力实现 adapter。
Receipt 与文本发送到所配置 AI 服务；无 Key 或断网时仍可手工记账，输入留在本地等待处理。

拍摄候选使用 VisionKit 文档相机，图片导入使用系统照片选择器。需验证文档相机交互是否满足拍照即记录目标。
来源：[VNDocumentCameraViewController](https://developer.apple.com/documentation/visionkit/vndocumentcameraviewcontroller)。

## 8. Place 与地图

Place Resolution 在 Expense 创建后异步进行，失败不回滚消费。搜索依据为商户、地址与已知账本上下文。
MapKit 提供地址 / POI 搜索，MKMapItem 可带有可持久化的地点 identifier。
来源：[MKLocalSearch](https://developer.apple.com/documentation/mapkit/mklocalsearch)、[Place identifier](https://developer.apple.com/documentation/mapkit/mkmapitem/identifier-swift.property)。

Place 使用内部 UUID；provider ID 作为可选外部引用。商户名称相同不能自动视为同一家分店。
本地保存本产品使用的地点关联与必要坐标；外部结果缓存范围在确定 provider 时核对适用条款。
没有可靠候选时保留 unresolved。低质量候选不自动插入错误 Pin。
同 Place 聚合 Expense；地图空间聚类与同 Place 聚合分别处理。统计金额按币种分组。
地图业务数据只读本地，底图离线能力取决于系统缓存。

## 9. Export As / Save As（V1）与未来协同

2026-09-23 用户确认 Export As / Save As 使用 XLSX：从本地账本生成可分享的工作簿。无需写入 Google Sheets，也不建立持续同步。

### 9.1 用户流程

账本页面的更多菜单提供“导出…”和“另存为…”；本地编辑始终自动保存，这两个入口创建当前账本在导出时刻的独立副本。

- Export As：生成 XLSX 后打开系统分享面板。
- Save As：使用相同 XLSX 文件生成逻辑，随后选择文件名和保存位置。
- 两个入口复用一个 Export Service；不切换当前账本的存储位置，也不在每次编辑后重新导出。
- 首版范围为当前完整账本，不增加日期筛选和跨账本批量导出。
- 取消不修改账本；生成失败可重试。系统报告目标写入完成后才显示“已保存”；分享完成不宣称接收方已成功导入。
- 本地文件生成无需网络；选择外部云盘位置时，上传与离线可用性取决于对应文件服务。

### 9.2 XLSX 内容

一个工作簿导出当前账本的有效业务数据：

- 账单：每笔 Expense 一行，含稳定 ID、商户、发生时间与时区、币种、总额、分类和地点。
- 项目：每条 expenseLine 一行，含账单 ID、行 ID、名称、类别和金额；同一张账单的项目保持关联，不拆成多笔消费。
- 分摊：每条项目 × 承担成员一行，含行 ID、成员 ID / 名称和本地引擎计算的承担金额。
- 付款：每条 expensePayment 一行，含账单 ID、付款成员和金额。
- 余额：按本地 Ledger Engine 输出成员余额、结算币种与缺失汇率提示，不混加不同币种。

金额从整数最小单位转换，保留原币与小数位；避免经由 Double 累计。用户 / AI 文本一律写成文本单元格，不能被当作公式执行。只导出有效业务记录，不包含凭据、私有对话、AI 原始响应、已删除记录或撤销历史。XLSX 是阅读 / 分析文件，不承诺无损导入或账本恢复。

### 9.3 UIKit 与本地实现

Export Service 读取一致的数据库快照，在后台生成完整 XLSX 后再交给系统；文件生成期间不持有长时间写事务。支持取消、磁盘不足错误和临时文件清理，失败不显示为已导出。

Export As 使用 UIActivityViewController；Save As 使用 UIDocumentPickerViewController(forExporting:asCopy:) 并按副本导出。
来源：[系统分享](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller)、[文件导出选择器](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init%28forexporting%3Aascopy%3A%29)。

### 9.4 后续范围

当前不做 Google Sheets 写入、OAuth Connector 或自动回写。未来若单独提出导入恢复或持续协作需求，再定义其格式、身份与冲突规则；文件导出不建立同步关系。

## 10. 待确认决策

- D1：已确认先做本地持久化 / 计算，CRDT 与服务器后置；SQLite + GRDB 保持为当前建议实现。
- D2：Exact Split 在产品第 18 节为 V1 必须，第 37 节为 P1；建议作为第一版本地账本纠错能力。
- D3：V1 是否每账本单币种？是否需要手工记录“已经还款”以闭合 AA 使用流程？
- D4：首个 AI provider / model；用真实且可用于测试的票据集比较提取质量和延迟。
- D5：余额展示采用直接债务还是简化债务；退款暂不支持还是作为独立类型？

这些未决项不阻碍本地架构与 UI 信息结构的讨论，但相应实现要等语义确定。文件导出按第 9 节推进；导入与持续共享单独讨论。

## 11. 验证重点

- 领域：金额精度、确定性舍入、均分 / 精确分配、请客、个人消费、余额守恒、失效成员、撤销前置条件。
- 持久化：事务回滚、命令去重、删除恢复、任务中断重试、迁移后金额与票据关联不变。
- Agent：无效结构、多目标引用、重复响应、迟到响应、超时、恶意票据文本不能越过 Domain。
- 端到端：冷启动读本地；断网创建 / 修改 / 余额 / Undo；AI 失败后重启仍可看到票据并重试。
- 导出：一致快照、XLSX 金额精度 / 公式文本化、账单与项目关联、取消、磁盘不足、系统目标写入失败与凭据排除。
- UI：不同 iPhone 尺寸、键盘遮挡、Dynamic Type、VoiceOver、深浅色与减少动态效果。
- 指标：本地输入持久化延迟与 AI 完成延迟分别度量；Receipt → Expense < 10 秒是产品目标，不是网络 SLA。

实现顺序与逐项完成条件见 [todo](todo.md)。
