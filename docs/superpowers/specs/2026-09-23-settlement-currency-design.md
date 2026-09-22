# 结算币种与汇率 Spec

日期：2026-09-23。状态：已实现。
上游：[本地数据模型 Spec](2026-09-23-local-schema-design.md)；参考实现：`~/trips` 的 trip-ledger 表格（USD / JPY / CNY 混记，按「元/USD、元/JPY」手动汇率折人民币结算）。

## 1. 决策

- 每个账本有一个**结算币种**，和录入默认币种（`defaultCurrency`）分开。日本旅行：录入默认 JPY，结算 CNY。
- 汇率是账本级、**手动**的：每个外币一行「1 单位外币 = 多少结算币种」，与表格 D7 同义。
- 汇率**不实时更新**。用户在账本设置点「更新汇率」时才联网拉一次；拉完仍可手改。断网沿用上次值。
- journal 不变：每笔仍按原币种过账，每币种每笔 tx 和为 0。折算只在展示时做，改汇率 = 全账本重算。

## 2. 持久化（迁移 v3）

```
ledger        + settlementCurrency TEXT NOT NULL（迁移时回填为 defaultCurrency）
exchangeRate  ledgerId → ledger (cascade), currency, rate TEXT(Decimal),
              source ('manual' | 'fetched'), asOf DATE?, updatedAt
              PRIMARY KEY (ledgerId, currency)
```

- `rate` 用 Decimal 文本存，不用 double。
- `asOf` 为拉取时数据源给出的日期；手改时清空，`source` 变为 `manual`。

## 3. 折算

- 每个成员：按币种求 journal 净额 → `minor × 10^-exponent × rate` 四舍五入到结算币种最小单位 → 求和。
- 结算币种自身 rate 恒为 1，不存。
- 缺某币种汇率时不猜：该币种不参与折算，结果带 `missingRates`，UI 提示「缺少 USD 汇率」。
- 已知误差：分摊在原币种最小单位上取整（JPY 到 1 円、USD 到 1 分），与表格「先折算再除」相比，每人每笔最多差 1 个原币最小单位的折算值。trips 数据实测每人差 ≤ 0.2 元；合计可能差几分（每币种各自取整）。

## 4. 拉取汇率

- 数据源：Frankfurter（欧洲央行数据，免费、无需 key）。
  `GET https://api.frankfurter.dev/v1/latest?base=<结算币种>&symbols=<外币,…>`，结果取倒数（保留 8 位小数）。
- 拉取范围：账本内出现过的非结算币种 ∪ 已有汇率行。
- 不支持的外币会被数据源静默丢弃 → 保持原值并提示「未获取」；结算币种不被支持（404）→ 提示只能手填。
- 按日期取历史汇率（`/v1/2026-09-20`）数据源支持，V1 不做。

## 5. UI

- Activity 导航栏「⋯」→ 账本设置（SwiftUI `Form`）：结算币种、汇率列表（可编辑）、「更新汇率」按钮与「欧洲央行 · 2026-09-22 / 手动」来源标注。
- 余额卡片改为显示折算后的结算币种金额；有缺失汇率时显示提示。
- Agent 上下文带上折算后的余额与所用汇率。

## 6. 验证

- golden test：trips 表格的 16 笔共同消费 + 个人消费，USD 6.71、JPY 0.043 → 结算 CNY，与表格结果
  whitewater +10610.51 / innei −2793.12 / neko −2327.15 / rizumu −5490.23 每人差 < 1 元（见第 3 节误差），合计偏差不超过成员数（分）。
- 缺汇率时返回 missingRates，不抛错。
- 切换结算币种清空汇率。
