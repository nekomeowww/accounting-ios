# Agent 记账卡片 Spec

日期：2026-09-23。状态：单项目与多项目记账卡片已实现。
后续演进：[pi Agent 与 JavaScriptCore 接入 Spec](2026-09-23-pi-agent-runtime-design.md) 替代本文的 provider 与工具历史表示；卡片确认和事务入账规则继续有效。
上游：[Agent Chat Spec](2026-09-23-agent-chat-design.md)；[结算币种 Spec](2026-09-23-settlement-currency-design.md)；[小票凭证数据模型建议](../../technical/receipt-data-model.md)（只吸收原则，不建表）。

## 1. 范围

- 用户在 Chat 里用自然语言描述一笔消费，Agent 调用 `propose_expense`，聊天里出现一张**记账卡片**。
- 用户点「记账」才写入账本；点「取消」丢弃。Agent 自己永远不写库。
- 一张账单对应一次 `propose_expense`、一张卡片和一笔 Expense。无明细时保留原有单项目输入；有明细时每个项目分别指定金额与承担人，一次确认原子入账。

不做：税费折扣的自动拆解、exact 分摊、改账 / 删除 / 撤销、读数据的工具（余额和最近 20 笔已经在 system prompt 里）、图片输入。

## 2. 工具

`propose_expense`，输入：

| 字段 | 必填 | 说明 |
|---|---|---|
| merchant | ✓ | 商户或事项 |
| amount | ✓ | 十进制字符串，原币主单位，如 `"9700"`、`"12.50"` |
| currency | ✓ | ISO 4217 |
| payer | ✓ | 成员名 |
| consumers | | 成员名数组；省略 = 全员 |
| items | | 同一张账单的项目数组；每项 `name`、`amount`、可选 `consumers`。项目未指定承担人时沿用顶层 `consumers`，再省略则为全员 |
| occurred_at | | `yyyy-MM-ddTHH:mm`，本机时区；省略 = 现在 |
| category / note | | 文本 |

`amount` 是整张账单总额；填写 `items` 时，项目金额之和必须与它相等。System prompt 规则（来自凭证文档第 7 节）：金额 / 付款人不清楚先追问，不猜；币种没说用账本默认币种；告诉模型当前对话者是哪个成员（「我」）；不编造抹零；一张账单不拆成多次工具调用；卡片出现后不要声称已记账；改账和删除暂不支持。

## 3. Provider

- `AgentProvider.stream(system:turns:tools:)` 产出 `AgentEvent`：`.text(String)` / `.toolCall(id, name, arguments JSON)`。
- Anthropic：`content_block_start(tool_use)` 记下 id / name，`input_json_delta` 累加，`content_block_stop` 时发出。
- OpenAI 兼容：`delta.tool_calls[index]` 按 index 累加 id / name / arguments，`finish_reason` 或 `[DONE]` 时发出。
- 历史不回放 tool_use / tool_result：卡片在历史里转成一句 assistant 文本（含状态），相邻同角色消息合并。这样两家 provider 都不受配对约束。

## 4. 持久化（迁移 v4）

```
message + kind TEXT NOT NULL DEFAULT 'text'   ('text' | 'proposal')
        + payload TEXT                          工具入参 JSON 原文
        + proposalState TEXT                    'pending' | 'accepted' | 'dismissed'
        + expenseId TEXT → expense              accepted 后填
```

- 一次 assistant 回合：文字消息照旧；每个 tool call 追加一条 `kind=proposal` 消息。回合没有文字时删除那条空文字消息。
- 「记账」在**同一写事务**里：确认 `proposalState = 'pending'` → 解析校验 → 建 Expense + journal → 标记 accepted + expenseId。重复点击或重试不会重复入账（凭证文档第 8 节的幂等要求，以状态迁移代替 commandId）。
- `source = agent`。

## 5. 解析与校验（本地）

- 成员名按忽略大小写匹配；找不到就在卡片上显示「找不到成员 X」，禁用「记账」。
- 总额与每个项目金额 × 10^exponent 必须是正整数；项目数组非空、名称非空、合计等于总额，否则报错。
- 校验结果是 `ExpenseDraft` 或错误文案，卡片据此渲染；真正写入仍走 `ExpenseBuilder` 的领域校验。

## 6. UI

卡片（SwiftUI，`UIHostingConfiguration`）：商户、总额（+ 结算币种折算）、付款人、逐项目金额与承担人、时间 / 分类 / 备注；单项目沿用简洁分摊展示。底部按钮：
- pending：「取消」「记账」
- accepted：「已记账 ›」，点击进入 Expense 详情
- dismissed：「已取消」灰显
- 无法解析：错误文案，只有「取消」

## 7. 验证

- AgentClient：两家 provider 的 tool call 分片累加测试。
- Persistence：accept 幂等（两次 accept 只产生一笔 Expense）；dismissed 后 accept 失败；解析失败不写库。
- 模拟器：真 provider 说「晚饭 9700 日元 白水付的 四人分」→ 卡片 → 记账 → Activity 出现、余额变化。
- 多项目：一张 ¥2,580 账单包含 ¥1,250 个人、¥900 另一人、¥430 两人均分；只生成一张卡片，确认后只生成一笔三行 Expense，欠款与项目金额一致。总额不符不生成卡片。
