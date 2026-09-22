#if DEBUG
import AgentClient
import Foundation

struct ScriptedAgentProvider: AgentProvider {
    static let defaultsKey = "debug.mockAgent"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    func stream(system: String, turns: [ChatTurn], tools: [ToolSpec]) -> AsyncThrowingStream<AgentEvent, Error> {
        let input = turns.last { $0.role == .user }?.text ?? ""
        let me = system.firstMatch(of: /用户是成员「(.+?)」/).map { String($0.1) } ?? "me"
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if input.localizedCaseInsensitiveContains("fail") || input.contains("失败") {
                        try await Self.type("正在处理…", into: continuation)
                        throw AgentError.http(status: 500, body: "模拟的服务端错误")
                    }
                    if let amount = input.firstMatch(of: /\d+(\.\d+)?/).map({ String($0.0) }) {
                        try await Self.type("好的，整理成一张记账卡片，确认后再记入账本。", into: continuation)
                        let payload: [String: Any] = [
                            "merchant": input.replacingOccurrences(of: amount, with: "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(24).description,
                            "amount": amount,
                            "currency": input.uppercased().contains("CNY") || input.contains("元") ? "CNY" : "JPY",
                            "payer": me,
                            "category": "餐饮",
                        ]
                        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                        continuation.yield(.toolCall(ToolCall(id: UUID().uuidString, name: "propose_expense", arguments: json)))
                    } else {
                        try await Self.type(Self.markdownSample, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func type(_ text: String, into continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        var chunk = ""
        for character in text {
            chunk.append(character)
            if chunk.count >= 3 {
                continuation.yield(.text(chunk))
                chunk = ""
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        if !chunk.isEmpty { continuation.yield(.text(chunk)) }
    }

    private static let markdownSample = """
        这是**本地模拟 Agent** 的回复，用来检查流式渲染。

        - 列表项一
        - 列表项二，带 `inline code`

        | 成员 | 应付 |
        |---|---|
        | innei | ¥2,793.06 |
        | neko | ¥2,327.23 |

        输入里带数字会生成记账卡片；带「失败」或 fail 会模拟错误。
        """
}
#endif
