# Expense 项目数据模型对比

调研日期：2026-09-23。按实际源码提取关键表 / ORM 实体，省略登录、配置等非核心字段；关系描述不代表每个引用都有 SQL 外键。未运行数据库迁移或完整应用。

状态更新：第 8 节保留研究时的候选建议。当前已落地的 participant/member、逐行分摊、transfer 和 journal 以 [本地数据模型 Spec](../superpowers/specs/2026-09-23-local-schema-design.md) 为准；Receipt 的扩展提案见 [凭证模型](../technical/receipt-data-model.md)。

## 1. Spliit：账本成员 + 分摊规则

核验版本 `cc796210db06bb112609f820c8eb8d7bbecdce83`。
[Prisma schema](https://github.com/spliit-app/spliit/blob/cc796210db06bb112609f820c8eb8d7bbecdce83/prisma/schema.prisma)。

| 实体 | 关键字段 | 作用 |
| --- | --- | --- |
| Group | id, name, currency, currencyCode | 账本 / 分账群组 |
| Participant | id, groupId, name | 群组里的成员，无须先是登录账号 |
| Expense | id, groupId, paidById, amount: Int, splitMode, isReimbursement, expenseDate | 单个付款人的消费或还款 |
| ExpensePaidFor | expenseId, participantId, shares: Int | 消费与承担成员的关联；联合主键 |
| ExpenseDocument | id, expenseId?, url, width, height | 一笔消费可有多张附件 |
| Activity | id, groupId, activityType, participantId?, expenseId?, data? | 活动记录，不是完整 before/after 撤销模型 |
| Category | id, grouping, name | 分类 |

结构：Group → Participant / Expense；Expense → ExpensePaidFor → Participant；Expense.paidById → Participant。

splitMode 为 EVENLY / BY_SHARES / BY_PERCENTAGE / BY_AMOUNT。shares 字段的意义随模式变化，而不是一律表示最终承担金额；最终分配由计算代码生成。
还款复用 Expense，并使用 isReimbursement 标记。核心 schema 没有独立的 Settlement、Balance、商品明细 Item 或地点 Place 实体。

[分摊计算](https://github.com/spliit-app/spliit/blob/cc796210db06bb112609f820c8eb8d7bbecdce83/src/lib/shares.ts) 与 [余额计算](https://github.com/spliit-app/spliit/blob/cc796210db06bb112609f820c8eb8d7bbecdce83/src/lib/balances.ts)。

对我们的启发：Member 不依赖账号；消费和承担人用关联表。我们还需独立保存 Items / Place / Receipt 的提取事实，不能直接照搬这一份较小的 schema。

## 2. SplitPro：账号成员 + 实际分摊金额

核验版本 `fd089df2af9b2f4c7110923932f3f7816909cd38`。
[Prisma schema](https://github.com/oss-apps/split-pro/blob/fd089df2af9b2f4c7110923932f3f7816909cd38/prisma/schema.prisma)。

| 实体 | 关键字段 | 作用 |
| --- | --- | --- |
| User | id: Int, name, email | 全局用户 |
| Group | id: Int, publicId, userId, name, simplifyDebts, archivedAt | 群组 |
| GroupUser | groupId, userId | 用户可参与多个群组，联合主键 |
| Expense | id: UUID, groupId?, paidBy, addedBy, amount: BigInt, currency, splitType, deletedAt | 消费、结算、调整等统一记录 |
| ExpenseParticipant | expenseId, userId, amount: BigInt | 每人的实际有符号分摊金额，联合主键 |
| ExpenseNote | id, expenseId, createdById, note | 消费备注 |
| GroupDefaultSplit | groupId, splitType, shares: Json | 群组默认规则 |
| BalanceView | userId, friendId, groupId?, currency, amount | 从有效消费和分摊派生的 SQL 视图 |

groupId 可空，所以支持群组外两人记账。splitType 包含 EQUAL、PERCENTAGE、EXACT、SHARE、ADJUSTMENT、SETTLEMENT、CURRENCY_CONVERSION。
旧 Balance / GroupBalance 模型仍留在 schema 中，但明确标注弃用，不应据此推荐同时维护账目与可写余额表。

[BalanceView SQL](https://github.com/oss-apps/split-pro/blob/fd089df2af9b2f4c7110923932f3f7816909cd38/prisma/migrations/20251108122842_add_balance_view/migration.sql) 排除 deletedAt 不为空的消费和成员欠自己的行，按双方、群组、币种聚合，并输出相反方向的余额。其有符号金额约定不能直接当成我们的正数 owedAmount 使用。

对我们的启发：保存最终分摊份额，余额派生；但 UserID 不宜直接替代我们的离线 MemberID。当前不引入它的账号、银行和周期任务基础设施。

## 3. Actual Budget：账户交易模型

核验版本 `4350045c3bb0a1d93fa1763f4fb1d7185c2e64fe`。
[初始 SQL](https://github.com/actualbudget/actual/blob/4350045c3bb0a1d93fa1763f4fb1d7185c2e64fe/packages/loot-core/src/server/sql/init.sql)、[当前数据库类型](https://github.com/actualbudget/actual/blob/4350045c3bb0a1d93fa1763f4fb1d7185c2e64fe/packages/loot-core/src/server/db/types/index.ts)。初始 SQL 需要结合后续迁移，不当作完整当前 schema。

| 实体 | 核心数据 | 作用 |
| --- | --- | --- |
| accounts | id, name, offbudget, closed, tombstone | 资金账户 |
| transactions | id, acct, amount, category, description, parent_id, transferred_id, date, tombstone | 收支交易；SQLite amount 为 INTEGER |
| payees | id, name, transfer_acct, tombstone | 收款方 / 对手方 |
| categories / category_groups | id, name, group, tombstone | 分类和分类组 |
| 预算记录 | month, category, amount 等 | 按月份与分类安排预算 |

transactions.parent_id 用于拆分交易的父子关系；transferred_id 用于转账对端引用。底层 description 与对外查询的 payee 命名存在映射，不能臆造 transactions.payee_id 列。

这里的 split 是把一笔支出拆到不同分类等明细，不是“几个成员分别欠了多少”。可参考整数金额、稳定引用、软删除和迁移方式；AA 的 Member / Allocation 仍需自己定义。
项目有 CRDT 消息表，但我们的同步已后置，当前不采纳这部分 schema。

## 4. Dime：轻量 Core Data 对象模型

核验版本 `0463cb8caba237de781ae02e70a2ec82ae900c67`。
[当前模型](https://github.com/rafsoh/dimeApp/blob/0463cb8caba237de781ae02e70a2ec82ae900c67/app/dime/Data/MainModel.xcdatamodeld/MainModel%202.xcdatamodel/contents)。已核对 .xccurrentversion 指向 MainModel 2。以下是 Core Data 实体，不是由我们直接操作的 SQL 物理表。

| 实体 | 关键字段 / 关系 |
| --- | --- |
| Transaction | id, amount: Double, date, income, note, recurringType；关联 Category |
| Category | id, name, emoji, colour, income；关联多笔 Transaction / TemplateTransaction 和至多一个 Budget |
| Budget | id, amount: Double, startDate, type；关联 Category |
| MainBudget | amount: Double, startDate, type |
| TemplateTransaction | id, amount: Double, income, note, recurringType；关联 Category |

模型较小，重点是个人分类、预算与重复记账，没有 AA 的承担人关联。Double 金额不是我们的采用建议；我们继续使用整数最小货币单位。

## 5. Receipt Wrangler：Receipt + Item 同时承载商品与份额

核验版本 `a30396153a5d462ca8def44e81aef2189ad9a5b8`。来源：[Receipt](https://github.com/Receipt-Wrangler/receipt-wrangler/blob/a30396153a5d462ca8def44e81aef2189ad9a5b8/api/internal/models/receipt.go)、[Item](https://github.com/Receipt-Wrangler/receipt-wrangler/blob/a30396153a5d462ca8def44e81aef2189ad9a5b8/api/internal/models/item.go)、[FileData](https://github.com/Receipt-Wrangler/receipt-wrangler/blob/a30396153a5d462ca8def44e81aef2189ad9a5b8/api/internal/models/file_data.go)。

| 模型 | 核心字段 / 关系 |
| --- | --- |
| User | ID, Username, DisplayName, IsDummyUser；支持虚拟成员 |
| GroupMember | UserID + GroupID 复合主键，GroupRoleID |
| Receipt | ID, Name, Amount, Date, PaidByUserID, GroupId, Status, ResolvedDate |
| Item | ReceiptId, Name, Amount, ChargedToUserId?, IsTaxed, Status |
| item_linked_items | Item 的自关联多对多表，将关联份额和原 Item 连接 |
| FileData | ReceiptId, Name, FileType, Size；附件 metadata |

实际没有独立 Share 模型。商品与份额共用 Item，charged_to_user_id 表示分配对象；LinkedItems 经关联表连接，读取时过滤顶层列表中的关联分项。
基础 ID 是 uint，不是 UUID。Receipt.Amount 使用 Go decimal.Decimal，GORM 指定 decimal(10,2)；Item 的 decimal(20,3) 位于旧 sql tag，未经运行时 DDL 验证，不能直接当作实际列精度。
Receipt 没有逐笔 currency_code；系统 CurrencyDisplay 是显示设置。该模型不直接满足我们的逐笔币种语义。

启发：识别与分配都有明细关联，但我们更适合明确拆开 ExpenseItem 和 Allocation，避免一个 Item 同时表示商品和债务份额。

## 6. Frappe HRMS：报销主单 + 费用子表 + 支付引用

核验版本 `32a4d00976b85d65382674e41e4d9548780f4a3a`。来源：[Expense Claim](https://github.com/frappe/hrms/blob/32a4d00976b85d65382674e41e4d9548780f4a3a/hrms/hr/doctype/expense_claim/expense_claim.json)、[Detail](https://github.com/frappe/hrms/blob/32a4d00976b85d65382674e41e4d9548780f4a3a/hrms/hr/doctype/expense_claim_detail/expense_claim_detail.json)、[Advance](https://github.com/frappe/hrms/blob/32a4d00976b85d65382674e41e4d9548780f4a3a/hrms/hr/doctype/expense_claim_advance/expense_claim_advance.json)、[业务计算](https://github.com/frappe/hrms/blob/32a4d00976b85d65382674e41e4d9548780f4a3a/hrms/hr/doctype/expense_claim/expense_claim.py)。

| DocType | 核心字段 / 关系 |
| --- | --- |
| Expense Claim | employee, company, expense_approver, approval_status, status, currency, exchange_rate；申请 / 批准 / 预付款 / 已报销汇总金额 |
| Expense Claim Detail | expense_date, expense_type, description, amount, sanctioned_amount, base_amount, base_sanctioned_amount, default_account, cost_center, project |
| Expense Claim Advance | employee_advance, advance_paid, unclaimed_amount, allocated_amount, return_amount；reference_type / reference_name 指向支付凭据 |
| Employee Advance | employee, advance_amount, paid_amount, claimed_amount, return_amount, pending_amount, currency, status |
| Expense Taxes and Charges | 报销单税费子表 |

Frappe 从 DocType 生成表，文档主键是 name。子表通过框架 parent / parenttype / parentfield / idx 建立关系，不是每个 JSON 都声明 expense_claim_id。
申请金额与批准金额分开；审批状态与支付状态也分开。已报销金额由 ERPNext 的 Payment Entry Reference / Journal Entry Account 引用汇总，而非仅设置 Paid 标志。附件通过框架通用 File 的 attached_to_doctype / attached_to_name 关联。

金额字段声明为 Currency，框架映射为 decimal(21,9)，不是我们的 Int64 最小货币单位方案；业务代码还使用 flt() 与字段 precision，不能称其所有运算均使用任意精度 Decimal。
框架来源：[子表关系](https://github.com/frappe/frappe/blob/719c38d59ea0b3a54ba15fb94a14477086cf510c/frappe/model/base_document.py)、[Currency 类型映射](https://github.com/frappe/frappe/blob/719c38d59ea0b3a54ba15fb94a14477086cf510c/frappe/database/mariadb/database.py)、[File](https://github.com/frappe/frappe/blob/719c38d59ea0b3a54ba15fb94a14477086cf510c/frappe/core/doctype/file/file.json)。

启发：消费 / 申请、审批、真实付款分开保存。V1 只需要其中的消费与结算边界，不引入企业审批链或会计科目。

## 7. Odoo 19 Community：费用直接关联会计凭证

核验 19.0 分支提交 `57fad2e46286b74d3832a3c7cea4a84327268224`，来源：[hr_expense.py](https://github.com/odoo/odoo/blob/57fad2e46286b74d3832a3c7cea4a84327268224/addons/hr_expense/models/hr_expense.py)。这里描述的是 Odoo 19，不套用旧版本 Expense Sheet 模型。

核心 `hr.expense` 模型包含 employee_id、company_id、manager_id、vendor_id、product_id（费用类别）、currency_id、total_amount_currency、total_amount（公司币种）、approval_state、state。
payment_mode 区分 own_account（员工垫付待报销）与 company_account（公司付款）；account_move_id 指向 account.move 会计凭证，amount_residual 关联凭证未付余额。
税费通过 expense_tax 关联 account.tax；附件经 ir.attachment 的 res_model / res_id 关联。split_expense_origin_id 是费用拆分来源引用，不是 AA 成员分摊。
金额在 ORM 中声明为 Monetary，本次未继续追踪 ORM 到数据库的物理类型，不将其推定为整数最小单位。

启发：费用发生、付款来源、审批与会计凭证是不同概念。我们的消费账本不需要引入这套完整会计体系。

## 8. 对本项目的建议（尚未批准为最终 schema）

优先采用“账本成员 + 实际份额”，保留分摊规则用于解释和重新编辑：

```text
Ledger
  ├── Member
  ├── Expense ── payerMemberID → Member
  │     ├── ExpenseParticipant → Member（实际参与的人）
  │     ├── ExpenseAllocation  → Member（实际承担金额）
  │     ├── ExpenseItem ── ItemParticipant → Member
  │     ├── Receipt → 本地资源与提取结果
  │     └── Place
  ├── Settlement → fromMemberID / toMemberID（若纳入范围）
  └── Action
```

- ExpenseParticipant 与 ExpenseAllocation 分开：四个人吃饭但 A 请客，参与者是四人，成本由 A 全额承担。成员可以既是参与者也是承担者，也可以只属于其中一类。
- 分摊模式与输入规则保留，但实际 allocation 是确定、可校验、可导出的金额，份额之和必须等于 Expense.total。
- Settlement 建议独立表示还款，不能再次增加消费总额；这是我们的设计建议，并非 Spliit / SplitPro 的现状。是否进入 V1 仍待讨论。
- Balance 先不建可写事实表。若加入 Settlement，成员净应收 = 垫付 - 承担 + 已付还款 - 已收还款，按币种计算。
- Receipt / Item 是证据与明细；Expense / Allocation 是已校验账务事实，AI 识别结果不直接成为余额。
- 使用 UUID、整数金额、外键与事务；跨行的份额守恒在 Domain 提交边界校验。该建议不引入服务器或 CRDT。
