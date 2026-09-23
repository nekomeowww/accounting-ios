# 设备内 Agent 的 JS 封装

对应 [pi/JSC Spec](../docs/superpowers/specs/2026-09-23-pi-agent-runtime-design.md) 的 PI-1 / PI-2；配套持久化在 `LedgerPersistence/AgentStore.swift`（PI-3），App 的 `ChatSession` 已接入（PI-4a）。参考 Kansoku `agentSession.ts` 的会话边界和 AITravelOS 的 JSC bootstrap，使用真实 pi-agent-core / pi-ai 0.85.1；不维护第二套 Agent 循环或 SSE 解析器。

```sh
cd Runtime
npm ci --ignore-scripts --no-audit --no-fund
npm run check
npm test
npm run build
npm run verify:jsc
# iOS：先启动指定模拟器，显式传入其 UDID；不会安装/重置 App
python3 verification/run.py --ios <booted-simulator-udid>
```

单元测试使用 Node 24 自带 runner；JSC 验证编译真实 Swift 宿主并请求本地 HTTP fixture，不连接付费模型服务。`dist/agent.js` 是 browser-target IIFE，导出 `AccountingAgent.configure/run/abort/dispose` 与原生回调入口；TS 会话封装仍在 `src/session.ts`。构建产物忽略入库，由 lockfile 重建。

Xcode 的 `Build pi Agent runtime` 阶段调用 `build-for-xcode.sh`，lockfile 变化时执行 `npm ci`，构建 JS 并复制到 App 的 `AgentRuntime/agent.js`，随后由正常 App 签名流程签名。构建机器需要 Node/npm，设备不包含 Node。

## 宿主约定

- `SessionConfig` 注入完整模型配置、Keychain 提供的 key、当前账本 prompt、工具声明和带稳定 ID 的历史。OpenAI 兼容模型显式使用 `openai-completions`；模型名称、上下文长度等由后续设置适配提供。
- `SessionHost.fetch` 由原生网络桥接实现；两种真实 pi provider 都使用它。runtime 显式关闭 provider 重试。
- `run(runId, { id, message })` 发送新输入；`run(runId)` 从已装载历史继续。宿主提供唯一 runId 和用户消息 ID。已在数据库保存的用户消息通过 checkpoint 幂等 upsert，不重复插入。
- 每个会话只创建一个可运行的 session；其内部拒绝并发 run。跨 session 实例的会话互斥由 Swift 协调层负责。
- `checkpoint` 在每条完整消息结束时被等待。工具执行前先保存 assistant/toolCall，下一次模型请求前先保存 toolResult。回调失败立即停止运行并返回 failed。
- `executeTool` 接收 assistant 消息 ID、toolCallId、参数和取消信号；宿主负责账本绑定、领域校验、副作用与结果原子提交。普通工具错误抛出后由 pi 回传模型；原生请求必须在取消/释放时终结，不能留下悬挂 Promise。
- UI 事件带 conversationId/runId，消息与工具事件带稳定关联 ID。取消后不再输出展示增量，但仍保存 pi 产生的完整中断消息。`settled` 是唯一运行终态，不能把 pi 的 prompt Promise resolve 当作成功。
- `messages` 返回完整、独立复制的历史。恢复应从数据库选择一致检查点，补齐已有工具执行记录，再创建新 session；不能直接对以失败 assistant 结尾的历史调用 continue。

## 当前交付边界

已完成 provider 选择、工具闭环、消息事件、检查点回调、取消、运行互斥与错误分类。测试覆盖 OpenAI 工具闭环、异步提交顺序、恢复不重做工具、写入失败阻断、鉴权失败、取消到网络、工具错误和 Anthropic 文本流。

`PiAgentRuntime` 已提供原生宿主，所有 JSC 操作在专用串行队列执行。Swift 初始化时传入配置 JSON 和 async handler；handler 接收 `checkpoint`、`tool`、`event` 操作及 JSON，返回 JSON（无返回值用 `null`）。默认从 App bundle 加载脚本，测试可指定 URL。调用 `run(id:inputJSON:)` 等待结果；Task 取消会传到 Agent；显式 `close()` 或宿主释放会取消原生请求、异步 handler 和定时器，并终结等待方。

JS 在 provider 加载前安装 Web API globals。UTF-8 编解码通过原生 Foundation 实现，JS 仅保留流式解码未完成的字节后缀，不使用实验中的 deprecated `text-encoding`。Blob/FormData 保留用于 SDK 的类型检测，并不代表已支持上传。

网络桥接当前支持选定 provider 使用的 GET/POST 文本请求和 SSE / JSON 响应：

- 原样传递请求头、状态码、响应头和错误体；只允许配置 provider 的同源 URL，跨源重定向不跟随；HTTPS 为默认，HTTP 仅允许 loopback。
- 不使用持久 Cookie 或系统凭据，SDK console 日志不输出，以免泄露 key / prompt。
- JS stream 高水位 64 KiB，原生每块最多 16 KiB；耗尽消费额度时暂停 URLSessionDataTask，读取后恢复。
- 非流式响应读取上限 1 MiB；请求空闲超时 60 秒、总资源超时 300 秒。不实现通用浏览器 fetch 或二进制/多部分上传。

11 个 Node 行为测试通过；真实 macOS / iOS 26.5 Simulator JSC 验证覆盖两种 provider、原生鉴权头/错误体、Swift 工具、检查点、重建恢复、取消、关闭时清理以及跨源重定向拒绝。iOS 验证使用 9 个本地请求，并检查没有自动重试或鉴权头跨源泄露。正常签名的 App 模拟器构建通过，JS 资源已打入包。

## GRDB 持久化接入约定

v5 迁移新增 `agentRun`、`agentTranscript`、`agentToolExecution`，以及 message 的 Agent 关联。原始 pi 消息按会话序号保存，带格式版本；toolResult 关联原始 assistant 消息 ID。流式 UI 文本单独保存，不参与工具执行。

- `beginAgentRun` 原子保存用户消息和运行记录，返回运行 ID、历史 JSON 和输入 JSON。历史不包含当前输入，避免 prompt 重复添加；随后的用户 checkpoint 是幂等确认。数据库唯一索引限制每个会话一个 active run。
- `checkpointAgentMessage` 对应 JS 的 checkpoint 回调，保存完整消息并投影 assistant 文本。重复消息 ID 只能携带相同内容；工具调用结果必须按原始顺序配对。
- `updateAgentText` 保存流式 UI 文本。终态运行和已完成消息拒绝迟到写入。
- `executeAgentProposal` 从绑定会话确定账本，校验原始已持久化 toolCall 和参数。卡片与执行结果在同一事务提交；相同会话/assistant 消息/toolCallId 重送返回原结果。`isError` 为 true 时，调用方把 `errorMessage` 抛回 pi；数据库错误不得作为工具成功返回。
- `finishAgentRun` 保存终态；数据库启动时把遗留 running 改为 interrupted，流式 UI 消息改为失败。
- 用户显式重试时调用 `resumeAgentRun`。它保留所有审计历史，过滤失败/中断的 assistant 上下文，先用执行记录补齐工具结果，再准备 `continue`。对于尚未执行的 `propose_expense`，使用原始调用 ID 在事务内执行；不存在可重放的任意外部副作用。已完成卡片不会重建。
- 若最终 assistant 回复已保存而终态未写入，`resumeAgentRun` 仅将原运行修复为 complete 并返回 nil，不启动模型请求。否则返回新的 runId、修复后历史与 nil inputJSON。
- 首次启用时事务性导入旧 complete 消息，旧卡片只转换为文本摘要，不伪造工具历史。`agentProposalContext` 提供下一次请求所需的卡片最新状态，原始工具结果保持不变。

持久化与领域测试在 iOS Simulator 上通过；AgentStore 行为测试覆盖 v4 升级、并发重送、事务回滚、磁盘重开、部分回复、无文字失败重试、工具错误/账本隔离、运行与消息顺序、旧历史导入与终态修复。金额校验拒绝数字后的杂字符及 Int64 溢出；卡片确认校验其所属账本。

ChatSession/UI 已切换到 pi，旧 Swift provider 与调试模拟入口已移除。已在独立 iOS Simulator 使用 DeepSeek 的 OpenAI 兼容接口验证真实流式回复、工具卡片、确认入账和重启恢复。真实 Anthropic 服务与真机尚未验收。
