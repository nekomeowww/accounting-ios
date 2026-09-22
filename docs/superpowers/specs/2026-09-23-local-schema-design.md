# 本地数据模型 Spec

日期：2026-09-23。状态：已讨论定稿，待实现。
上游：[技术 Spec v0.1](../../technical/technical-spec-v0.1.md) 第 5、6 节；本文件覆盖其中与本文冲突的部分。

## 1. 决策

- 存储引擎：SQLite + GRDB，Swift Package 依赖，版本在 `Package.resolved` 锁定。
- 两层模型：**事件层**记录发生了什么（面向人），**journal 层**用统一形状记录钱的归属（面向余额）。两层在同一个 SQLite 事务内写入；journal 可由事件层重建。
- 分摊粒度到小票行。税、服务费、小费、折扣、抹零都是行。
- `participant` 与 `member` 分离：前者是账目里出现的名字，后者是有账本权限的身份。Guest 就是没有 `member` 绑定的 `participant`。
- 余额按币种独立，不在录入时换汇。跨币种结算由 `transfer` 显式声明抵消了哪种币的多少债务。
- 金额一律 `Int64` 最小货币单位 + ISO 4217 代码，禁止浮点。小数位数由 Domain 的 `Money` 类型查表得出，不入库。

## 2. 表

审计列 = `createdAt TEXT, updatedAt TEXT, deletedAt TEXT?, version INTEGER, createdBy TEXT, updatedBy TEXT`。
时间为 GRDB 默认的 UTC 文本 `YYYY-MM-DD HH:MM:SS.SSS`。ID 为 UUID 字符串。`createdBy / updatedBy` 为本机 actor UUID（首次启动生成，存 UserDefaults）。
所有列表查询过滤 `deletedAt IS NULL`。表名与列名用 GRDB 习惯的单数 camelCase。

### 2.1 账本与人

```
ledger        id PK, name, type, defaultCurrency, 审计列
participant   id PK, ledgerId → ledger, name, 审计列
member        id PK, ledgerId → ledger, participantId → participant, actorId,
              role ('owner'|'editor'|'viewer'), 审计列
              UNIQUE(ledgerId, actorId)
```

- V1 每个账本一行 `member`：本机 actorId 绑定“我”这个 participant。未来账号与协作在此表扩展，账目行不动。
- Guest 不是角色。拉一个朋友进来 = 插入一条 `participant`，不建 `member`。同一个朋友第二次吃饭复用同一行。
- 已被账目引用的 participant 只能软删除（tombstone），不能物理删除。

### 2.2 消费

```
expense         id PK, ledgerId → ledger, merchant, note?, category?,
                occurredAt, timeZone, currency,
                latitude REAL?, longitude REAL?, horizontalAccuracy REAL?,
                locationSource ('device'|'photo'|'manual')?,
                source ('manual'|'agent'), 审计列
expenseLine     id PK, expenseId → expense,
                kind ('item'|'tax'|'service'|'tip'|'discount'|'rounding'),
                name, quantity INTEGER, unitMinor INTEGER?, amountMinor INTEGER,
                splitRule ('weighted'|'exact'|'proportional'), sortOrder INTEGER
lineConsumer    lineId → expenseLine, participantId → participant,
                weight INTEGER NOT NULL DEFAULT 1, exactMinor INTEGER?
                PK(lineId, participantId)
expensePayment  expenseId → expense, participantId → participant,
                amountMinor INTEGER CHECK(amountMinor > 0), method?
                PK(expenseId, participantId)
```

- Expense 没有 `total` 列。总额 = 所有行 `amountMinor` 之和；`discount` 行为负数。
- 每个 expense 至少一行。没有条目信息的小票就是一行 `kind='item'`、`name=merchant`、`amountMinor=total`。
- `latitude / longitude / horizontalAccuracy` 是捕获时的原始 GPS：拍照时取设备定位（`device`），导入图片取 EXIF（`photo`），手动记账可选（`manual`）。它不是解析后的地点；M6 的 `place` 表是独立实体，`expense.placeId` 届时以迁移追加。
- `expensePayment` 支持多付款人；和之和必须等于行之和。
- `occurredAt` 存时刻，`timeZone` 存标识符，按天分组用后者。

### 2.3 分摊规则

对每一行独立计算，结果写入 `journalEntry`（见 2.5）。

| splitRule | 参与者 | 分配 |
|---|---|---|
| `weighted` | `lineConsumer` 行 | 按 `weight` 比例。全部为 1 即均分；2 表示“他吃了两份”；0 表示在场但不承担（请客时除付款人外全为 0） |
| `exact` | `lineConsumer` 行 | 取 `exactMinor`，之和必须等于行 `amountMinor` |
| `proportional` | 不需要 `lineConsumer` | 按每个 participant 在本 expense 内 `kind='item'` 行的承担小计比例分配。用于税、服务费、小费、折扣、抹零 |

`proportional` 行在所有 `item` 行算完之后计算。整单请客时 item 行只有付款人承担，`proportional` 行自然也全归付款人。

**余数分配**：先按比例向下取整，余下的最小单位按 `participantId` 升序逐个加 1。负数行对绝对值做同样计算后取负。相同输入在任何设备得到相同结果。

### 2.4 结算

```
transfer   id PK, ledgerId → ledger, fromParticipantId → participant, toParticipantId → participant,
           currency, amountMinor INTEGER CHECK(amountMinor > 0),
           settlesCurrency, settlesMinor INTEGER CHECK(settlesMinor > 0),
           method?, externalRef?, occurredAt, kind ('settlement'|'refund'), note?, 审计列
```

- `currency / amountMinor` 记录实际转了什么（100 USDT），只作展示。
- `settlesCurrency / settlesMinor` 记录抵消了哪种币的多少债务（JPY 15,000），进 journal。同币种时两组值相同。
- 一笔转账清两种币的债 = 两条 transfer。
- `method` 是自由字符串（`cash / alipay / wechat / usdt / bank`…），`externalRef` 留给未来银行、支付宝导入。不建 `paymentMethod` 表。

### 2.5 Journal

```
journalTx      id PK, ledgerId → ledger, sourceType ('expense'|'transfer'), sourceId,
               occurredAt, reversesTxId → journalTx?
journalEntry   id PK, txId → journalTx, participantId → participant, currency,
               amountMinor INTEGER（带符号）, lineId → expenseLine?
               INDEX(participantId, currency)
```

符号约定：正数 = 应收，负数 = 应付。

- Expense 过账：每个付款人 `+amountMinor`（`lineId` 为空）；每行每个承担者 `−owed`（带 `lineId`）。
- Transfer 过账（在 `settlesCurrency` 上）：from `+settlesMinor`，to `−settlesMinor`。
- 不变量：同一 `journalTx` 内每种币种的 entry 之和为 0。
- 余额：`SUM(amountMinor) GROUP BY participantId, currency`。
- 对账单：某 participant 的 entry 按 `lineId` 连回行名，能写出“意面 1,200 + 税 96”。
- 撤销 / 删除：写一条 `reversesTxId` 指向原 tx 的反向 journalTx，同时对来源行打 `deletedAt`。不修改或删除已有 entry。
- 修改 expense：反向旧 tx + 新 tx，事件行原地更新并 `version + 1`。

## 3. 写入边界

Domain 提供命令（`createExpense`、`updateExpense`、`deleteExpense`、`recordTransfer` 等），每个命令在一个 GRDB 写事务内：

1. 校验：所有 participant 属于同一账本；`weighted` 行至少一个 `weight > 0` 的承担者；`exact` 行的 `exactMinor` 之和等于行金额；至少一个 `item` 行；payment 之和等于行之和；至少一个付款人。
2. 写事件行。
3. 计算分摊，写 `journalTx` + `journalEntry`。
4. （M2 起）写 `action`，`commandId` 唯一约束保证重试幂等。

校验失败整个事务回滚。UI 表单与 Agent Proposal 走同一组命令。

## 4. 模块与查询

- `Packages/LedgerKit/Sources/LedgerDomain`：`Money`、实体值类型、分摊算法、命令定义。不依赖 GRDB 与 UIKit。
- `Packages/LedgerKit/Sources/LedgerPersistence`：GRDB record、`DatabaseMigrator`、`LedgerStore`（`DatabasePool`）、命令执行、`ValueObservation` 查询。依赖 LedgerDomain。
- App 的 Activity 列表订阅一个查询：某账本未删除的 expense，按 `occurredAt` 倒序，附带总额、付款人名字、承担人数。按天分组在 Swift 侧完成。余额摘要订阅 journal 的分组求和。

## 5. 迁移计划

- `v1`：本文 10 张表。
- `v2`（M2）：`action`。
- `v3`（M3）：`receipt`、`input`、`processingJob`，`expense.receiptId`。
- `v4`（M6）：`place`，`expense.placeId`。

只追加迁移，不改已发布迁移。每个迁移用上一版 fixture 验证。

## 6. 验证

- 分摊：均分、加权、exact、proportional、请客、个人消费、负数行、余数分配顺序、JPY（0 位小数）与 2 位小数币种。
- Journal：每笔 tx 每币种和为 0；余额随 expense / transfer / 撤销变化正确；从事件层重建的 journal 与现存一致。
- 持久化：校验失败回滚；杀进程重启后数据一致。

## 7. 不做

- 全局 `person` 表（跨账本同一个人）。
- `paymentMethod` 表。
- 录入时换汇、汇率表。
- 周期性消费。
- Place、Receipt、Action：按第 5 节迁移追加。
