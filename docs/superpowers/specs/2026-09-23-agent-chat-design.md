# Agent Chat 页面 Spec

日期：2026-09-23。状态：已讨论定稿，待实现。
后续演进：[pi Agent 与 JavaScriptCore 接入 Spec](2026-09-23-pi-agent-runtime-design.md) 替代本文的 Swift provider 与运行时方案。
上游：[产品 Spec v0.2](../../product/product-spec-v0.2.md) 第 31、32 节；[本地数据模型 Spec](2026-09-23-local-schema-design.md)。

## 1. 范围

- 每个账本一个对话页，push 自 Activity 页底部的“Ask Agent…”入口。
- 真 provider（BYOK）：Anthropic Messages API 与 OpenAI 兼容接口，流式输出。
- 对话消息落库，杀进程后可恢复；对话不是账本事实，不进 journal。
- Agent 只读账本上下文，不带工具、不改账。

不做：工具调用 / 改账、图片输入、Markdown 渲染、多会话、消息编辑、相机入口。

## 2. 导航

- `ActivityViewController` 底部固定一个玻璃胶囊 `UIButton`“Ask Agent…”，点击 `push ChatViewController(ledger:)`。
- `ChatViewController` 首次进入时若该账本无 `conversation`，创建一条。
- 账本列表右上角齿轮 → `AgentSettingsViewController`（`UIHostingController<AgentSettingsView>`）。

## 3. Chat 页

### 3.1 列表

`UICollectionView` + `UICollectionViewCompositionalLayout.list`（`.plain`，无分隔线）+ diffable data source，item identity 为 `message.id`。

| cell | 内容 |
|---|---|
| 用户消息 | SwiftUI 气泡，右对齐，`UIHostingConfiguration` |
| Agent 消息 | `CKTextView`，左对齐；流式时用 `CKTextReveal` 按 tick 推进，`CKTextView.setText(animate:)` 渲染；完成后 `finish()` |
| 失败 | 错误文案 + “重试”按钮，重试用同一条用户消息重新请求 |

新消息或流式增量到达时滚到底；用户手动上滑离底部超过一屏后不再自动滚动，直到再次接近底部。

### 3.2 Composer

底部 `UITextView`（多行，最高 5 行）+ 发送按钮；流式进行中发送按钮变为停止。用 `view.keyboardLayoutGuide` 避让。无 API Key 时顶部显示“未配置 AI 服务”的提示条，点击进设置，发送禁用。

## 4. 持久化（迁移 v2）

```
conversation  id PK, ledgerId → ledger, createdAt, updatedAt
message       id PK, conversationId → conversation, role ('user'|'assistant'),
              text, status ('streaming'|'complete'|'failed'), error?, createdAt, updatedAt
              INDEX(conversationId, createdAt)
```

- 发送：同一事务插入用户消息（`complete`）和 Agent 占位消息（`streaming`，空文本）。
- 流式期间每 300ms 把累计文本写回 Agent 消息；结束时写最终文本并置 `complete`；出错置 `failed` 并记 `error`。
- `LedgerStore` 启动时把所有 `streaming` 改成 `failed`（error = "interrupted"）。
- 后续 `action` 表改为迁移 v3。

## 5. AgentClient（新 target，Foundation only）

```swift
public struct ChatTurn { role: user | assistant; text: String }
public protocol AgentProvider: Sendable {
    func stream(system: String, turns: [ChatTurn]) -> AsyncThrowingStream<String, Error>
}
```

- `AnthropicProvider(apiKey:model:)`：`POST https://api.anthropic.com/v1/messages`，header `x-api-key`、`anthropic-version: 2023-06-01`、`content-type: application/json`；body `{model, max_tokens: 16000, stream: true, system, messages}`；只取 `content_block_delta` 中 `delta.type == "text_delta"` 的 `text`；`message_stop` 结束；非 2xx 抛错并带响应体。默认 model `claude-opus-5`。
- `OpenAICompatibleProvider(baseURL:apiKey:model:)`：`POST {baseURL}/chat/completions`，`Authorization: Bearer`；body `{model, stream: true, messages}`（system 作为第一条 `system` 消息）；取 `choices[0].delta.content`；`data: [DONE]` 结束。
- `SSEParser`：把 `URLSession.bytes(for:)` 的行流拆成 `(event, data)`，忽略空行与注释；有单元测试。
- 取消：调用方取消 Task 即中断；provider 不做重试。

### 5.1 上下文

system prompt（中文）：
- 角色说明：这是账本“{name}”的记账助手，只能基于给定信息回答，不能声称已修改账本。
- 成员列表。
- 最近 20 笔消费：日期、商户、金额币种、付款人、承担人数。
- 各币种余额摘要。

turns = 该会话按时间排列的全部 `complete` 消息（不含 `failed` 的 Agent 消息）。

## 6. 设置

`AgentSettings`（UserDefaults）：`provider ('anthropic'|'openai')`、`model`、`baseURL`。API Key 存 Keychain（`kSecClassGenericPassword`，service `dev.innei.Accounting.agent`，account = provider）。

`AgentSettingsView`（SwiftUI Form）：provider Picker、model TextField（带默认值）、base URL TextField（仅 openai）、API Key SecureField、保存。

## 7. 模块

- `Packages/LedgerKit/Sources/AgentClient`：providers、SSE parser、`ChatTurn`。无 UIKit / GRDB 依赖。
- `Packages/LedgerKit/Sources/LedgerPersistence`：`Conversation`、`Message` record，迁移 v2，`ChatStore` 扩展（open/insert/update/observe）。
- `Packages/LedgerKit/Sources/LedgerDomain`：不变。
- `App/Sources/Chat/`：`ChatViewController`、`ChatCells`、`ChatComposerView`、`ChatSession`（驱动 provider 与落盘）、`AgentContextBuilder`、`AgentSettings*`。

## 8. 验证

- 单元：SSE 解析（多行 data、跨 chunk 断开的行、`[DONE]`）、Anthropic 与 OpenAI 事件到文本增量的映射、`streaming` 启动恢复为 `failed`。
- 手工（verify-app skill）：无 Key 时提示；配置 Key 后发送一条“我们一共花了多少”，看到流式回复；流式中杀进程重开，消息为失败态可重试。
