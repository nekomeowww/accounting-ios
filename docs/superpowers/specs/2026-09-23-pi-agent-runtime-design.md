# pi Agent 与 JavaScriptCore 接入 Spec

日期：2026-09-23。状态：聊天链路已切换；DeepSeek 的 OpenAI 兼容接口已在 iOS Simulator 实测，真实 Anthropic 与真机验收待完成。PI-1 JS 封装、PI-2 JSC 宿主与 App 资源打包、PI-3 持久化和 PI-4a ChatSession/UI 已实现。进度见 [实施 todo](../../technical/todo.md)，当前交付见 [Runtime](../../../Runtime/README.md)。

上游：[Agent Chat Spec](2026-09-23-agent-chat-design.md)、[Agent 记账卡片 Spec](2026-09-23-agent-expense-proposal-design.md)。本 Spec 替代其中的 Swift provider、纯文本工具历史和单次模型请求设计；记账卡片的用户确认、领域校验和事务入账规则保持有效。

## 1. 目标与范围

在设备内通过 JavaScriptCore 执行 pi-agent-core 和 pi-ai，实现完整的「模型请求 → 工具调用 → 工具结果 → 模型继续回复」循环。

- pi 负责模型协议、流式解析、Agent 循环和消息上下文。
- Swift 负责 JSC 宿主、原生网络、账本工具、Keychain、GRDB 和聊天 UI。
- 首版保留 Anthropic 与 OpenAI 兼容接口、文本输入和 `propose_expense`。
- 每个账本沿用现有会话；同一会话同时只允许一个运行中的回合。
- 对话和 Agent transcript 不进入账本 journal；真正入账仍走既有领域逻辑。

不扩展多会话 UI、图片/PDF、改账/删除工具、后台持续运行、远程 JS 更新、桌面 OAuth、文件系统工具或通用插件系统。暂不引入自动网络重试。

## 2. 参考实现与已验证边界

### 2.1 Kansoku：pi 封装

参考相邻工作区 `kansoku-workspace/repos/kansoku/packages/core/src/ai/`：

| 文件 | 采用的设计 |
| --- | --- |
| `agents/agentSession.ts` | 统一创建 Agent；注入 model、tools、messages、sessionId、transformContext；封装 prompt、continue、abort、事件订阅 |
| `conversation/conversationEngine.ts` | 会话运行互斥、历史装载、事件转换、完成/取消/失败状态管理 |
| `runtime/providerOverrides.ts` | 自定义 Base URL；OpenAI 兼容服务显式采用 completions 协议 |

参考其职责边界，不直接搬入完整 conversation engine。Node UUID、Bun OAuth、环境变量/文件凭证、交易业务、usage 文件日志及自动网络重试不进入 iOS 封装。会话 ID 由 Swift 提供，凭证来自 Keychain。

Kansoku 的回合末尾增量保存不足以覆盖移动端杀进程场景；本项目在工具执行边界增加持久化检查点。

### 2.2 AITravelOS：JSC 宿主

参考相邻项目 `AITravelOS/experiments/pi-jsc/` 的 `runtime.ts`、`probe.ts`、`Probe.swift` 和 `build.mjs`。

该实验锁定 `@earendil-works/pi-agent-core` 与 `@earendil-works/pi-ai` 0.85.1；README 记录 iOS 26.5 Simulator 验证通过，现存 `dist/ios.log` 有 PASS。本次方案核对了源码与留存日志，没有重跑。

已覆盖真实 pi Agent 和 OpenAI completions provider、URLSession SSE、参数分片、UTF-8 跨块、异步 Swift 工具、原生网络取消，以及完成工具后在新 JSContext 中恢复且不重复执行工具。不需要重新做这一轮可行性实验。

尚未覆盖真实服务鉴权、Anthropic、完整 HTTP 错误处理、真机性能、后台执行、未完成副作用的恢复。实验 fetch 仅支持本地 POST JSON + SSE，不能原样作为生产网络桥接。

## 3. 模块与所有权

```text
┌─────────────────────────────────┐
│ Swift ChatSession               │
│ 用户输入、UI 状态、GRDB、卡片确认 │
└────────────────┬────────────────┘
                 ▼
┌─────────────────────────────────┐
│ JS AgentSession                 │
│ pi core + pi-ai                 │
│ 模型协议、上下文、工具循环、事件   │
└────────┬───────────────┬────────┘
         ▼               ▼
┌────────────────┐ ┌────────────────┐
│ 网络宿主        │ │ 工具宿主        │
│ URLSession     │ │ Swift 领域逻辑  │
└────────────────┘ └───────┬────────┘
                          ▼
                  ┌────────────────┐
                  │ GRDB / 卡片    │
                  └────────────────┘
```

- TS 源码放在独立 runtime 目录，构建为单个 IIFE JS 资源，随 App 分发。构建机器使用 Node，设备不包含 Node。
- pi core / pi-ai 首版精确锁定已验证的 0.85.1，使用 lockfile；升级单独验证，不依赖上游 main 的 API。
- Swift `AgentClient` 承担 JSC 与网络桥接；账本工具通过宿主回调注入，避免 AgentClient 依赖 GRDB 或 UIKit。
- `ChatSession` 负责界面和业务协调，不再解析模型 SSE 或自行实现工具循环。
- 切换完成后移除不再使用的 Swift Anthropic/OpenAI provider 与模型协议解析代码，保留设置和 Keychain 数据兼容。
- 每次运行从数据库装载历史、构建当前 prompt 和工具；运行结束可释放 Agent/JSC，不依赖常驻 JS 内存维持会话。

## 4. JS 与 Swift 桥接契约

边界传递可序列化的数据，不跨边界暴露数据库连接或 Swift 业务对象。所有异步请求有请求 ID，所有运行事件有 `conversationId` 和 `runId`。

| 方向 | 操作 | 内容 |
| --- | --- | --- |
| Swift → JS | 启动 | 会话/运行 ID、模型配置、system prompt、历史、工具声明、新输入或继续执行指令 |
| Swift → JS | 取消 | 指定 runId，调用 pi abort 并取消关联宿主操作 |
| JS → Swift | 网络请求 | 请求 ID、目标 URL、method、headers、body；响应传回状态码、headers、字节块和结束/错误 |
| JS → Swift | 工具调用 | 请求 ID、toolCallId、工具名、参数；返回结果或结构化错误 |
| JS → Swift | 消息/运行事件 | 消息开始、文本增量、消息完成、工具开始/完成、运行完成/取消/失败 |
| JS → Swift | 持久化检查点 | 有序完整消息增量；必须等待宿主提交成功后才能越过相应执行边界 |

完整 pi `AgentMessage` 作为 transcript 内容保留。UI 事件携带稳定消息 ID；同一 assistant 消息的增量只更新自己的气泡，后续 assistant 消息创建新气泡。工具事件必须携带 toolCallId，不能仅用工具名关联。

`prompt()` Promise 完成不自动等于成功：封装需检查 pi 的错误状态与消息结束原因，区分正常结束、取消和失败。取消后不能再发成功终态。

## 5. JavaScriptCore 与网络

- 所有 JSContext/JSValue 操作在同一专用串行执行环境中完成；网络和工具回调先调度回该环境，UI 更新进入 MainActor。
- runtime globals 必须先安装，再加载 provider。按实际依赖补齐 AbortController/Signal、timers、URL、编码、Streams、Headers/Request/Response 等能力。
- 复用实验的 bootstrap 顺序；不直接采用其逐字节桥接方式。以字节块传输，UTF-8 解码必须支持跨块字符。
- 实验中的 deprecated `text-encoding` 和宽泛 polyfill 仅作为参考；生产实现按所选 provider 的依赖裁剪，但不得牺牲流式解码正确性。
- pi-ai provider 使用注入的原生 fetch。生产桥接覆盖所选 provider 实际使用的请求/响应语义：真实请求头、鉴权、响应头、状态码、错误体、流式读取与取消。
- API Key 持久化仍在 Keychain，只在运行需要时注入，不写 transcript、日志或 JS bundle。自定义 URL 与重定向必须避免向无关来源泄露鉴权信息。
- 网络流使用有界缓冲或消费反馈，不允许 JS 消费落后时无限堆积数据。
- abort、超时、JS 异常和宿主释放都要终结待处理 Promise，清理请求、监听器、定时器和原生任务；迟到回调按 runId 丢弃。
- 不承诺进入后台后继续完成。被系统终止后按数据库检查点恢复；首版不自动恢复网络执行。

## 6. 记账工具与确认

`propose_expense` 使用原生校验；单项目参数保持兼容，新增 `items` 支持一张账单逐项目分摊。账本 ID 取自绑定会话，不能由模型切换。总额与项目金额保持十进制字符串，项目合计校验、分摊和入账由 Swift 领域层完成。

成功创建卡片后立即返回工具结果，例如：

```json
{"proposalId":"…","status":"pending_confirmation"}
```

pi 将结果提供给模型继续回复。工具完成表示卡片已持久化，不表示已入账；不让工具 Promise 等待用户点击。

- 用户点「记账」仍在原生事务内完成 pending 检查、领域校验、Expense/journal 写入和 accepted 状态更新。
- 用户取消只更新卡片状态。
- 确认/取消状态在下一次请求上下文中提供，不改写原始工具结果，也不因此自动调用模型。
- 无法解析或不符合领域规则时返回工具错误，不写入账目；保留旧无效卡片的展示兼容。
- 首版工具顺序执行，减少卡片顺序和恢复歧义。

## 7. 持久化与恢复

继续使用现有 conversation/message 保存 UI 数据，增加 Agent transcript 和执行关联。迁移编号跟随实施时最新 schema，不预占编号。

最低数据要求：

- transcript：conversationId、会话内有序序号、runId、稳定消息 ID、格式版本、完整 pi 消息 JSON。
- run：关联用户输入、运行状态及错误；启动时将遗留运行标记为 interrupted。
- 工具关联：在会话内以原始 assistant 消息 ID + toolCallId 唯一标识一次调用，记录参数、结果和 proposalId。相同标识却不同参数视为错误。
- UI 消息关联 transcript 消息；proposal 关联工具调用。两者是同一历史的展示与执行记录，不能各自生成一套独立历史。

持久化顺序：

1. 用户输入先落库；恢复运行时不能重复插入该输入。
2. 含 toolCall 的完整 assistant 消息在执行工具前落库。
3. `propose_expense` 的卡片与工具执行结果记录在同一事务提交，之后才向 JS 返回成功。
4. 完整 toolResult 与后续 assistant 消息按顺序保存；运行终态在必要写入成功后发布。流式文本沿用节流落盘。

同一调用重送时返回已有结果和 proposalId，不再创建卡片。若在步骤 3 提交后、步骤 4 前终止，恢复时从执行记录补齐 toolResult，再继续模型请求；不能重新生成工具调用标识后重放副作用。

这只保证同一持久化工具调用的去重，不声称重新生成的相似提案具有语义级 exactly-once 保证。重试优先从已有调用/结果继续，不删除已完成卡片后重跑整轮。

JSContext 重建时从 GRDB 装载 transcript，并重新注入工具、模型及当前账本上下文。未完成 assistant 内容保留为中断展示，不伪装成完整可执行工具调用。没有工具结果的中断调用需依据执行记录判断；不能凭文本猜测是否成功。

旧消息没有完整工具协议：一次性按现有文本和卡片状态摘要导入，不伪造历史 toolCall/toolResult；记录迁移完成，避免重复导入。新消息保存真实 pi 协议。

实现落点：迁移 v5，`LedgerPersistence/AgentStore.swift`。`resumeAgentRun` 只接受最近一次失败/取消/中断的运行；修复后创建新的运行 ID，原历史与原工具调用标识保留。若最终回复已经完整落库，只修复终态，不重复请求模型。缺少执行记录的 `propose_expense` 在显式恢复事务内按原 ID 执行；该规则不推广为任意外部工具的自动重放。

## 8. UI 与错误处理

- 保留现有聊天入口、设置、流式文本和记账卡片。
- 一个用户回合可包含多个 assistant 消息；正确显示「文字 → 卡片 → 后续文字」。
- 工具执行中显示简短状态；工具失败可继续由模型解释，运行失败则显示重试入口。
- 用户停止后保存已完成工具结果和已有文本，停止后不再追加迟到输出。
- 单纯成功生成卡片且没有解释文字可以正常完成，不能照搬“没有 assistant 文本即失败”的判断。
- 数据库提交失败不能显示工具成功或入账成功。

## 9. 验收

复用 AITravelOS 的运行时实验结构，验证本项目产品链路，不另起同等范围的可行性项目。

| 场景 | 必须验证的行为 |
| --- | --- |
| 两种 provider | Anthropic、OpenAI 兼容接口真实鉴权与流式回复；自定义 Base URL 生效 |
| 工具闭环 | 生成卡片，工具结果进入下一次模型请求，模型明确尚待确认 |
| 消息顺序 | 工具前后文字在正确气泡中；多个卡片与 toolCallId 一一对应 |
| 流式边界 | 中文/日文 UTF-8 跨块、工具参数分片不丢失、不重复 |
| 取消与失败 | 原生请求确实取消；无迟到输出；非 2xx 错误体、断流、工具错误、JS 异常可结束运行 |
| 恢复 | 完成工具后重建 JSC 继续且不重做；卡片已提交但 transcript 未补齐时也不重复创建 |
| 幂等与入账 | 同一调用重复交付只生成一张卡；重复确认只入账一次；取消/非法参数不入账 |
| 历史兼容 | 旧文本/卡片仍可见且可作为上下文，新历史保持工具配对 |
| 资源与体验 | 同会话拒绝并发发送；重复打开/关闭无残留请求；真机检查流式响应与界面响应性 |

测试聚焦桥接行为、恢复边界和真实副作用，不为接口常量表或静态配置添加快照测试。以上是实施验收要求，不代表当前已完成。
