import Foundation
import LedgerDomain
import Security

enum AgentProviderKind: String, CaseIterable, Identifiable {
    case anthropic, openai
    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI 兼容"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5"
        case .openai: "gpt-4o"
        }
    }
}

struct AgentSettings: Equatable {
    var provider: AgentProviderKind
    var model: String
    var baseURL: String
    var apiKey: String
    var readsImages: Bool

    static func load() -> AgentSettings {
        let defaults = UserDefaults.standard
        let provider = AgentProviderKind(rawValue: defaults.string(forKey: "agent.provider") ?? "") ?? .anthropic
        let settings = AgentSettings(
            provider: provider,
            model: defaults.string(forKey: "agent.model.\(provider.rawValue)") ?? provider.defaultModel,
            baseURL: defaults.string(forKey: "agent.baseURL") ?? "https://api.openai.com/v1",
            apiKey: Keychain.read(account: provider.rawValue) ?? "",
            readsImages: readsImages(provider)
        )
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if settings.apiKey.isEmpty, let key = env["AGENT_API_KEY"] {
            let provider = AgentProviderKind(rawValue: env["AGENT_PROVIDER"] ?? "") ?? .anthropic
            return AgentSettings(provider: provider, model: env["AGENT_MODEL"] ?? provider.defaultModel, baseURL: env["AGENT_BASE_URL"] ?? settings.baseURL,
                                 apiKey: key, readsImages: env["AGENT_VISION"].map { $0 == "1" } ?? (provider == .anthropic))
        }
        #endif
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue, forKey: "agent.provider")
        defaults.set(model, forKey: "agent.model.\(provider.rawValue)")
        defaults.set(baseURL, forKey: "agent.baseURL")
        defaults.set(readsImages, forKey: "agent.vision.\(provider.rawValue)")
        Keychain.write(apiKey, account: provider.rawValue)
    }

    static func readsImages(_ provider: AgentProviderKind) -> Bool {
        UserDefaults.standard.object(forKey: "agent.vision.\(provider.rawValue)") as? Bool ?? (provider == .anthropic)
    }

    var isConfigured: Bool {
        !apiKey.isEmpty && !model.isEmpty && (provider == .anthropic || Self.isAllowedBaseURL(baseURL))
    }

    static func isAllowedBaseURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let host = url.host?.lowercased() else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host))
    }

    func configurationJSON(conversationId: UUID, systemPrompt: String, historyJSON: String) throws -> String {
        let history = try JSONSerialization.jsonObject(with: Data(historyJSON.utf8))
        let schema = try JSONSerialization.jsonObject(with: Data(ExpenseProposal.inputSchema.utf8))
        let repaymentSchema = try JSONSerialization.jsonObject(with: Data(RepaymentProposal.inputSchema.utf8))
        let api = provider == .anthropic ? "anthropic-messages" : "openai-completions"
        let url = provider == .anthropic ? "https://api.anthropic.com" : baseURL
        let config: [String: Any] = [
            "conversationId": conversationId.uuidString, "systemPrompt": systemPrompt, "apiKey": apiKey,
            // pi-ai omits the output cap when maxTokens is 0; OpenAI-compatible hosts have differing limits.
            "model": ["id": model, "name": model, "provider": provider.rawValue, "api": api, "baseUrl": url,
                      "reasoning": false, "input": readsImages ? ["text", "image"] : ["text"], "contextWindow": 200_000, "maxTokens": provider == .anthropic ? 16_000 : 0,
                      "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]],
            "history": history,
            "tools": [["name": "propose_expense", "label": "记账卡片",
                       "description": "为一张账单生成一张待确认记账卡片；逐项目分摊时用 items，按指定金额分摊时用 shares，一次确认整张账单。", "parameters": schema],
                      ["name": "propose_repayment", "label": "还款卡片",
                       "description": "成员之间直接转账还钱（不是消费）时，生成一张待确认还款卡片。", "parameters": repaymentSchema]],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
    }
}

enum Keychain {
    private static let service = "dev.innei.Accounting.agent"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
