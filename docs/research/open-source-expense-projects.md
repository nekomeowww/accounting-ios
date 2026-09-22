# 开源 Expense / 报销项目参考

调研日期：2026-09-23。依据：项目官方仓库、源码、许可证和 GitHub API。未部署这些项目；维护日期仅为查询时的仓库 pushed_at，不等于最近一次正式发布，也不是质量保证。

当前项目约束仍为 UIKit、iOS 26+、本地持久化与计算。本文仅提供设计和实现参考，不改变产品范围，不引入云同步依赖。

## AA 分账

### Spliit — 首选领域模型参考

[仓库](https://github.com/spliit-app/spliit)，MIT，Next.js / Prisma / PostgreSQL；查询时最后推送 2026-09-17。

支持成员分账、余额、还款记录、票据附件和可选收据识别。源码有 CSV / JSON 导出入口。它是服务端 Web 产品，不是原生 iPhone 本地账本。

优先阅读：

- [schema.prisma](https://github.com/spliit-app/spliit/blob/main/prisma/schema.prisma)：Group、Participant、Expense、ExpensePaidFor 和 isReimbursement。
- [shares.ts](https://github.com/spliit-app/spliit/blob/main/src/lib/shares.ts)：最小金额单位的确定性分配、按成员 ID 排序，以及消费 ID 驱动的余数轮转。
- [balances.ts](https://github.com/spliit-app/spliit/blob/main/src/lib/balances.ts) 与 [测试](https://github.com/spliit-app/spliit/blob/main/src/lib/balances.test.ts)：余额守恒、还款建议。

设计判断：适合作为我们分摊与还款测试场景的参考；不能把服务端模型直接搬到本地。其 BY_AMOUNT 对异常旧数据有按比例分配的容错，我们的 Exact Split 仍应按自身领域规则严格校验，不能无意改变用户输入。

### SplitPro — 较完整的 AA 产品参考

[仓库与 README](https://github.com/oss-apps/split-pro)，MIT；查询时最后推送 2026-08-16。

支持均分、比例、份额、精确金额、调整、结算、负数消费和活动记录。README 描述金额使用 BigInt，余额由消费记录经数据库视图实时推导，也说明导入 Splitwise 暂只覆盖朋友与群组，没有导入消费。原有公共实例已停止维护，推荐自行部署。

设计判断：适合借鉴退款、结算、活动历史和债务简化的产品语义。它依赖服务端与认证，票据“本地磁盘”指部署服务器的磁盘，不是手机端 Local First。

## 本地记账与 iOS

### Actual Budget — 首选 Local First / 导出参考

[仓库](https://github.com/actualbudget/actual)，MIT；查询时最后推送 2026-09-21。

官方定义为 Local First 个人财务工具，提供本机桌面运行方式及可选同步。其业务偏预算、账户与交易，不是多人 AA，也不是 UIKit 工程。

建议参考 [导出与备份文档](https://github.com/actualbudget/actual/blob/master/packages/docs/docs/backup-restore/backup.md)、[备份实现](https://github.com/actualbudget/actual/tree/master/packages/loot-core/src/server/budgetfiles) 和 [交易模块](https://github.com/actualbudget/actual/tree/master/packages/loot-core/src/server/transactions)。目录名中的 server 不应单凭名字解释为必须远程运行。

设计判断：借鉴本地数据生命周期、导出恢复与业务计算组织。当前不因此重新启动我们已后置的 CRDT / 同步工作。

### Dime — 原生 iOS 产品体验参考

[仓库](https://github.com/rafsoh/dimeApp)，GPL-3.0；查询时最后推送 2025-03-29，未归档。旧地址 rarfell/dimeApp 已重定向至 rafsoh/dimeApp。

个人记账、预算、统计、周期消费、iCloud 同步与 Widget；仓库采用 SwiftUI，包含 Core Data 模型。适合观察快速录入、详情、统计的信息组织，不能当作 UIKit 脚手架。

### Expenso-iOS — 小型本地存储 / CSV 示例

[仓库](https://github.com/sameersyd/Expenso-iOS)，Apache-2.0；查询时最后推送 2023-10-02，未归档。

README 定位为展示 SwiftUI、Core Data、MVVM、生物识别和 CSV 导出的示例。适合小范围学习，维护较久未更新，不作为 iOS 26 工程基线。

## 票据与企业报销

### Receipt Wrangler — 首选 AI 票据流程参考

[主仓库](https://github.com/Receipt-Wrangler/receipt-wrangler)。API 与桌面子项目许可证为 AGPL-3.0，分别见 [api/LICENSE](https://github.com/Receipt-Wrangler/receipt-wrangler/blob/main/api/LICENSE) 和 [desktop/LICENSE](https://github.com/Receipt-Wrangler/receipt-wrangler/blob/main/desktop/LICENSE)。默认分支最近核验提交日期为 2026-09-22。

官方文档区分 Quick Scan（识别后直接保存）与 Magic Fill（预填后允许用户修改），也支持邮件接收票据。[AI 流程](https://receiptwrangler.io/docs/concepts/ai/)。这与我们的默认执行、保留人工纠正入口非常接近。

部署需要服务端组件，并不是手机端离线引擎。[部署要求](https://receiptwrangler.io/docs/getting-started/requirements/)。旧 API、Desktop 和 Mobile 仓库已合并至主仓，不能把旧仓库归档理解为整个项目停更。

设计判断：优先研究识别任务状态、失败处理、原始结果与用户纠正之间的关系，以及 receipt / item / share 建模。

### Frappe HRMS — 企业报销流程参考

[仓库](https://github.com/frappe/hrms)，[GPL-3.0](https://github.com/frappe/hrms/blob/develop/license.txt)；develop 最近核验提交日期为 2026-09-22。

[Expense Claim 官方文档](https://docs.frappe.io/hr/expense-claim) 明确区分申请金额与批准金额，支持审批 / 拒绝、审批意见与费用入账。适合借鉴“消费事实、报销申请、审批结果、付款状态”的分离。

设计判断：真正要研究企业报销时优先看它；我们的 AA 账本不需要顺带引入 HR / ERP 全套结构，企业审批仍不进入 V1。

### 企业报销补充

- [Open Collective API](https://github.com/opencollective/opencollective-api) 与 [Web 前端](https://github.com/opencollective/opencollective-frontend) 均为 MIT，默认分支核验于 2026-09-22 有提交。适合参考费用修改后的重新审批，以及附件 / 付款详情与公开摘要的权限区别。[重新批准](https://documentation.opencollective.com/fiscal-hosts/expense-payment/asking-for-information-about-expenses)、[报销提交](https://documentation.opencollective.com/expenses-and-getting-paid/submitting-expenses/submitting-a-reimbursement)。
- [Odoo Community hr_expense](https://github.com/odoo/odoo/tree/19.0/addons/hr_expense) 模块声明 LGPL-3，提供企业费用报销流程。Community 与 Enterprise 能力需分别看；官方票据数字化涉及付费 Extract/IAP 服务，不能把 OCR 全部归为免费自托管能力。[模块声明](https://github.com/odoo/odoo/blob/19.0/addons/hr_expense/__manifest__.py)、[Extract API](https://www.odoo.com/documentation/18.0/developer/reference/extract_api.html)。
- [Expensify/App](https://github.com/Expensify/App) 当前客户端使用 [MIT](https://github.com/Expensify/App/blob/main/LICENSE.md)。可参考 [API 设计指南](https://github.com/Expensify/App/blob/main/contributingGuides/API.md) 中的离线乐观写入、客户端 ID 与操作命令；客户端开源不能证明完整后端 / SmartScan 可自行部署。

## 建议阅读顺序

1. Spliit：消费、参与人、分摊、结算与余额测试。
2. Receipt Wrangler：Receipt → AI → 保存 / 纠错的处理流程。
3. Actual Budget：Local First 与文件导出 / 恢复。
4. Dime：原生 iPhone 的页面与输入体验。
5. Frappe HRMS：如果下一步需要细化企业报销，再研究其状态模型。

## Google Sheets 补充线索

[madytekt/spliit](https://github.com/madytekt/spliit/blob/main/README.md) 自述为 Spliit 衍生项目，MIT。README 描述 Google Apps Script 每晚将消费导出到 Google Sheets，按群组、全部消费和日志分表。查询时最后推送 2026-09-20，规模很小；尚未审查实际脚本或验证运行。

可以参考其单向输出的思路，但不能据此宣称 Spliit 上游内置 Google Sheets Connector，也不能把定时导出称为双向同步。

## 筛选备注

- [canopas/splito](https://github.com/canopas/splito) 在此次 GitHub API 和网页检查中均返回 404，不列为可获取的主要候选。
- [janishahn/expenses](https://github.com/janishahn/expenses) 虽有 iOS 26 SwiftUI 客户端与票据能力，但作者明确说明采用 PolyForm Noncommercial，属于 source-available，不列入开源主推荐。
- 本文列明许可证用于区分项目；当前没有复制任何第三方实现代码。
