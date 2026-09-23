# 实施 todo（讨论稿）

依据：[技术 Spec v0.1](technical-spec-v0.1.md) 与 [本地数据模型 Spec](../superpowers/specs/2026-09-23-local-schema-design.md)。已完成项按勾选记录；新增 Receipt 工作按 [小票凭证数据模型建议](receipt-data-model.md) 评审后实施。
每阶段交付可演示闭环，完成相应验证后再扩大范围。

## M0 — 固化关键决策

- [x] 创建公开仓库 nekomeowww/accounting-ios。
- [x] 确认 UIKit、iOS 26.0+、iPhone only、HIG。
- [x] 确认未来 Web + Apple。
- [x] 确认开发期 BYOK。
- [x] 确认 V1 加入 Export As / Save As，从本地账本生成 XLSX；无需 Google Sheets 写入或同步。
- [x] 确认先做本地持久化 / 本地计算，CRDT、同步实验和服务器后置。
- [x] 本地存储实现按 SQLite + GRDB 建议完成技术定稿（[本地数据模型 Spec](../superpowers/specs/2026-09-23-local-schema-design.md)）。
- [x] 币种：账本结算币种 + 手动汇率统一折算，按钮手动拉取（[结算币种 Spec](../superpowers/specs/2026-09-23-settlement-currency-design.md)）。
- [x] 确认 Exact Split、结算记录、退款与债务展示语义（技术 Spec D2 / D3 / D5）。
- [x] AI provider：BYOK，Anthropic + OpenAI 兼容（[Agent Chat Spec](../superpowers/specs/2026-09-23-agent-chat-design.md)）；测试票据来源：`~/trips` 真实旅行账本。
- [ ] 评审 Receipt 独立修订、字段证据、金额组成 / 支付 / 汇总，以及映射到现有 expenseLine / journal 的设计。

完成条件：技术 Spec 将选定项改为 accepted，保留未选方案与原因。

## M1 — 能运行的原生工程

- [x] App target：最低 iOS 26.0、设备族 iPhone、UIKit Scene 生命周期。
- [x] Swift 6、本地 package、依赖锁定；先以目录组织小模块。
- [x] 账本列表与账本页面导航、Activity、Agent 输入栏（Map 占位未做）。
- [ ] 确认模拟器构建和真机运行路径；补充 README 构建方式。（模拟器构建与 README 已完成，真机待验证）

完成条件：干净 checkout 可构建，iPhone 上系统导航、输入与返回行为正常。

## M2 — 完整本地账本

- [x] 按已定稿模型完成 Money、Participant / Member、ExpenseLine / LineConsumer / ExpensePayment 与 Journal 的实现和验证。
- [ ] 数据迁移、事务边界、查询观察、UUID、软删除与 Action Log。
- [ ] 区分 MemberID、ActorID 与设备上的当前成员偏好，业务实体不依赖云端账号。
- [x] 手工创建、修改、删除 Expense（均分、请客、个人消费；版本校验；删除/修改可撤销）。多项目账单的金额与分摊暂只能通过 Agent 修改；创建账本 / 成员 UI 待做。
- [x] 按 D2 决议加入 Exact Split（手工表单「指定金额」+ Agent 卡片 shares）。
- [x] Balance Engine：按币种 journal 净额 → 结算币种折算；golden test 对齐 trips 表格。
- [x] 债务展示（谁转给谁）与结算记录：点「结清方式」记录还款，计入余额，可左滑删除。
- [ ] 持久化 Undo 与命令幂等；修改目标的版本校验。
- [ ] 完成领域不变量、事务失败和重启恢复验证。

完成条件：飞行模式下记账、改账、算余额、撤销，杀进程重启后数据一致。

## M3 — 票据输入可靠落盘

- [ ] 相机 / 系统图片导入，评估拍摄确认步骤。
- [ ] 原图、缩略图、metadata 和相对路径；定义备份策略。
- [ ] 稳定 asset ID，业务数据 / 设备偏好 / 凭据 / AI 处理数据分离，为未来分享保留边界。
- [ ] Input / ProcessingJob 状态机，中断恢复与显式重试。
- [ ] Activity 显示待处理票据，详情可查看原图。
- [ ] 按凭证模型建议追加 localAsset / receipt / receiptPage，支持多页、文件缺失与中断恢复；旧账目迁移不伪造 Receipt。

完成条件：断网拍照或导入后退出 App，重开后票据与任务仍存在。

## M4 — Receipt → Expense

- [x] Keychain 与开发者 AI 设置；实现首个 provider adapter。
- [ ] 结构化 receipt extraction，保留 raw / normalized / evidence / model version。
- [x] 类型化 Proposal → Domain 校验 → 原子记账（自然语言 → 记账卡片 → 确认，[Agent 记账卡片 Spec](../superpowers/specs/2026-09-23-agent-expense-proposal-design.md)）。
- [x] `propose_expense` 支持一张账单的多个项目、逐项目承担人、一张卡片和一次事务确认。
- [ ] 收据识别出的 Items 持久化（Agent 记账卡片的多行账目已实现）。
- [ ] 默认付款人、参与者与均分推断；关键歧义澄清入口。
- [ ] 重试去重、迟到响应处理、金额与格式错误恢复。
- [ ] 追加 receiptExtraction / receiptRevision，以及商户、商品、税费、税组、支付、汇总、引用、注释和字段证据表；采用修订一次性提交。
- [ ] 实现 expenseReceipt / expenseLineReceiptSource：totalOnly 和 reconciledLines 都走现有 Domain / journal，重复识别不能重复入账或静默覆盖用户纠正。
- [ ] 覆盖已含税不重复计入、套餐不重复合计、小数数量、现金找零、礼品卡支付、后付小费、未知币种、溢出与未识别金额。

完成条件：真实票据可以自动进入 Activity 和余额；失败不丢输入，重试不重复记账。

## M5 — 自然语言改账

### pi / JavaScriptCore 接入

依据：[pi Agent 与 JavaScriptCore 接入 Spec](../superpowers/specs/2026-09-23-pi-agent-runtime-design.md)。

- [x] PI-1：JS AgentSession 封装（Codex，2026-09-23 完成）。[Runtime](../../Runtime/README.md) 锁定 pi 0.85.1，接入两个 provider、工具宿主回调、事件与检查点；8 个离线行为测试、TypeScript 检查和 browser bundle 构建通过。未接入 JSC/App，不代表真实服务验收。
- [x] PI-2：Swift JSC 宿主与网络桥接，打包资源接入 App（Codex，2026-09-23 完成）。原生异步回调、UTF-8、HTTP/错误体、背压、取消/关闭、同源限制已实现；11 个 JS 测试、真实 macOS/iOS Simulator JSC 离线验证及正常签名 App 构建通过。聊天链路切换和真实模型验收在 PI-4。
- [x] PI-3：GRDB transcript/run/工具执行记录、卡片原子去重与恢复（Codex，2026-09-23 完成）。v5 迁移、旧历史一次性导入、检查点/UI 关联、并发去重、失败事务回滚、磁盘重开恢复与迟到回调拒绝已实现；iOS Simulator 上持久化/领域共 34 个测试通过。
- [x] PI-4a：ChatSession/UI 切换到 pi（2026-09-23）。发送、流式文本、工具卡片、停止、失败重试与旧历史导入已接线；移除旧 Swift provider。Simulator 构建和持久化测试、离线 JSC 桥接验证通过。
- [ ] PI-4b：真实服务与真机验收。已用 DeepSeek 的 OpenAI 兼容接口在独立 iOS Simulator 验证流式回复、卡片工具闭环、确认入账和重启恢复；真实 Anthropic 与真机仍待验收。

### 自然语言改账业务

- [x] 最小 Agent Context（成员、当前用户、折算余额、近 20 笔）；Action 查询待 M2。
- [ ] 修改付款人、参与者、分摊方式与目标 Expense 解析。
- [ ] 多候选澄清、基于版本提交、Undo 的自然语言调用。
- [ ] 回执与追问嵌入 Activity，保持手工纠正入口。

完成条件：能演示“刚才 A 付的”“这笔我自己的”“这顿我请”和撤销，余额正确变化。

## M6 — 消费地图

- [ ] 可重试的 Place Resolution，分店匹配与 unresolved 状态。
- [ ] Place 本地存储、provider ID 和 Expense 关联。
- [ ] MKMapView、同地点聚合、Pin 预览、Expense Detail 跳转。
- [ ] 无网络 / 无候选不影响账本；现有地点能从本地读取。

完成条件：同一组 Expense 可在 Activity 与 Map 查看，地图失败不阻断记账。

## M6.5 — Export As / Save As

依赖 M2 / M3，可在本地账本与票据存储稳定后实现；与 AI 接入无强依赖。

- [ ] 账本更多菜单加入导出 / 另存为；同一 XLSX Export Service 生成文件。
- [ ] XLSX 包含账单、项目、逐项目分摊、付款与余额；稳定 ID 保留一张账单与多项目的关联。
- [ ] 一致快照、后台生成、取消、磁盘不足与临时文件清理。
- [ ] 系统分享面板和文件导出选择器；完成 / 取消反馈。
- [ ] 验证金额精度、公式文本化、多语言商户与多项目分摊，核对工作簿数据与本地账本一致。

完成条件：飞行模式下生成 XLSX，可保存至本机文件位置并发起系统分享；源账本保持不变，失败不误报成功。

## M7 — MVP 验收

- [ ] 多尺寸 iPhone、键盘、Dynamic Type、VoiceOver、深浅色与 Reduce Motion。
- [ ] 真实票据集的耗时、零修改率、追问率、地点匹配率，记录样本量与失败原因。
- [ ] 冷启动、断网、进程中断、重复请求、磁盘写入失败与迁移恢复。
- [ ] 文档更新，明确 V1 实际支持范围与已知限制。

完成条件：四人旅行场景从拍收据、分账、改账、撤销到地图完整演示。

## Later — 导入、更多格式与持续协同（当前不执行）

- [ ] 若以后需要导入 / 恢复，单独设计可恢复格式与验证规则；XLSX 不承担备份语义。
- [ ] 根据需求增加 PDF 或图片摘要。
- [ ] 持续共享：定义本地成员与账号关联、权限、修改传播和财务冲突语义。
- [ ] 再评估是否需要 CRDT、点对点或存储中转；届时决定是否进行 Swift ↔ Web 实验。
- [ ] 若以后明确需要外部 Connector 或同步，再独立定界；文件导出不建立自动同步关系。
- [ ] 无论传输方案如何，分摊、余额与业务校验继续由客户端完成。

以上均不作为 V1 本地持久化的前置条件。
