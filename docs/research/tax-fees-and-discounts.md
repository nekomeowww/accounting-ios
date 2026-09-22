# 税、服务费、小费与折扣建模

日期：2026-09-23。状态：源码调研与设计建议，尚未成为已确认技术决策。讨论的是票据记录与分账，不替商户判断各地税务规则。

状态更新：下文 ExpenseAdjustment 为研究时的候选设计。当前账本采用统一 expenseLine 表；新 [凭证模型建议](../technical/receipt-data-model.md) 将原始税费拆解放入 receiptAdjustment，并显式映射到现有入账行，避免重复引入可写账务事实。

## 轻量 AA 工具

Spliit 的 Expense 保存 amount、splitMode 和参与人 shares，没有税 / 服务费 / 小费 / 折扣专属字段。收据识别 schema 也只输出 amount、categoryId、date、title，提示词要求读取总额。
来源：[schema](https://github.com/spliit-app/spliit/blob/cc796210db06bb112609f820c8eb8d7bbecdce83/prisma/schema.prisma)、[提取实现](https://github.com/spliit-app/spliit/blob/cc796210db06bb112609f820c8eb8d7bbecdce83/src/app/groups/%5BgroupId%5D/expenses/create-from-receipt-button-actions.ts)。

SplitPro 的 Expense / ExpenseParticipant 同样以总额与成员金额为核心，没有专门的税费分解表或字段。结论限定于所检查的核心 schema，不代表用户不能手工建立名为“服务费”的消费。
来源：[schema](https://github.com/oss-apps/split-pro/blob/fd089df2af9b2f4c7110923932f3f7816909cd38/prisma/schema.prisma)。

因此它们能把含税费的最终金额拿来分账，但不是详细税费拆解模型。

## Receipt Wrangler 与 Frappe HRMS

Receipt Wrangler 的 Item 有 IsTaxed 布尔字段，但本次代码检索只找到模型、命令、表单、生成客户端和测试里的保存 / 传递，未发现它参与税额计算。不能把该字段描述为现成的税分摊引擎。
来源：[Item](https://github.com/Receipt-Wrangler/receipt-wrangler/blob/a30396153a5d462ca8def44e81aef2189ad9a5b8/api/internal/models/item.go)。

Frappe HRMS 的 Expense Taxes and Charges 子表有 account_head、description、rate、tax_amount、total、base_tax_amount、base_total 等字段。rate 是 Float，tax_amount 是 Currency。
其 calculate_taxes 按每条 rate × total_sanctioned_amount 计算；未指定 rate 时可以使用录入的 tax_amount。各税费行基于同一批准总额，未在这一方法中按顺序进行复合计税。
这一报销子表没有独立的 inclusive 标记、商品适用范围或 tip / serviceCharge / discount 分类，不应混同 ERPNext 完整销售 / 采购税引擎。
来源：[子表 schema](https://github.com/frappe/hrms/blob/32a4d00976b85d65382674e41e4d9548780f4a3a/hrms/hr/doctype/expense_taxes_and_charges/expense_taxes_and_charges.json)、[计算代码](https://github.com/frappe/hrms/blob/32a4d00976b85d65382674e41e4d9548780f4a3a/hrms/hr/doctype/expense_claim/expense_claim.py)。

## Odoo 的税务模型

Odoo 19 的 account.tax 有固定额、比例等计算方式；price_include 表达价格是否已含税，sequence 与 include_base_amount / is_base_affected 决定税的先后关系以及是否影响后续计税基础。
来源：[官方模型文档](https://www.odoo.com/documentation/19.0/developer/reference/standard_modules/account/account_tax.html)、[税设置与计算说明](https://www.odoo.com/documentation/19.0/applications/finance/accounting/taxes.html)。
这是可计算税务规则的会计系统。我们的 V1 记录商户已经出具的票据，只需要保留金额、证据和含税语义，不照搬完整税引擎。

## 本项目建议：金额组成与成员分配分开

要分别回答两个问题：这笔钱由哪些部分组成，以及这些部分由谁承担。税率 / 计税基础不等于成员分摊规则。

建议在 Expense / ExpenseItem 之外增加一组 ExpenseAdjustment 明细。这个名字表示金额组成的增减项，不表示同步修改操作；Action 仍负责修改历史。

| 字段 | 建议语义 |
| --- | --- |
| id / expenseID | 稳定身份与归属 |
| kind | tax / serviceCharge / tip / discount / rounding / other |
| label | 票据原始名称，如 Service Charge |
| amountMinor | 该组成项的有符号整数金额；折扣为负值 |
| inclusion | includedInBase / addedToBase / unknown；相对于所选择的明细基准金额，不能含糊地写 includedInTotal |
| rate? / baseAmountMinor? | 票据给出的比例及计算基础；比例用十进制字符串或有理数，缺失就留空 |
| scope | 整单或一组商品；不同税率可对应不同商品集合 |
| source | receipt / user / derived，以及对应提取证据 |

若以后实现 Item Split，再通过关联表记录 Adjustment 适用的 Items，以及成员分配金额；不要在 V1 为尚未启用的模式实现完整计算框架。
商品行的 lineTotal 同样必须有明确含税 / 折扣语义。仅给整张小票一个 isTaxIncluded 布尔值，不能覆盖混合税率和部分行已含税的情况。

### 计算规则

- 明确区分票据总额、商品基准金额与付款金额。收据可能打印 subtotal、含税 total、现金交付和找零，不应误把现金交付作为消费总额。
- 在基准明确且明细完整时：总额 = 商品基准之和 + addedToBase 组成项之和。includedInBase 只解释已经包含的金额，不再次相加。
- 例如税前 1,000、另加税 100、合计 1,100；或者含税商品价 1,100、内含税 100、合计 1,100，两张票据表达方式不同但消费总额相同。
- 商户列明的金额优先作为记录事实。税率与基础用于校验；不能根据猜测的当地税率覆盖票据金额。
- 无法确认含税或折扣基础时保留 unknown。总额、币种和付款人清楚时，仍可按总额均分；不必为了补齐税费明细阻断普通记账。
- 如果总额本身不明确，或正在做按商品分账而差额影响成员承担金额，应要求纠正，不能把差额自动叫作“税”或“舍入”。
- 小费可能在票据打印后另付：保留原票据 total，将明确的小费记录为后加项，得到最终 Expense.total。
- 真正的优惠折扣减少消费；礼品卡、预付余额或付款抵扣是否减少消费必须按其实际性质辨别，不能只看票据上有负号。

### 成员分配

V1 的整单均分 / Exact Split 直接作用于最终总额，Adjustment 主要用于展示与核对，不再额外分配一次。
Item Split 阶段：特定商品的税或折扣跟随该商品的承担者；整单服务费 / 小费可默认按相关商品承担金额比例分配，允许用户明确改为均分或指定人承担。
这只是产品默认值建议，不是唯一正确方式；服务费也可能按人头或只适用部分商品，必须保留用户意图。
折扣应先明确分配对象与计算基础，再分配相关费用；如税率基础包含服务费，不能简单把税与服务费都按商品原价重算。
每个需要分配的组成项采用整数余数分配，最终所有成员 allocation 之和必须严格等于 Expense.total。分配已含税金额时，税的拆解只能用于解释，不重复增加债务。

### V1 的最小实施边界建议

现在保存多条税费 / 折扣的结构化提取结果、含税语义和最终总额；仍按总额执行均分或精确分账。后续 Item Split 再增加组成项到商品 / 成员的完整分配能力。所有核对和分摊在本地完成。
