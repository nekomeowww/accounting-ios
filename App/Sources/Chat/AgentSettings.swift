import AgentClient
import Foundation
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
        case .anthropic: AnthropicProvider.defaultModel
        case .openai: OpenAICompatibleProvider.defaultModel
        }
    }
}

struct AgentSettings: Equatable {
    var provider: AgentProviderKind
    var model: String
    var baseURL: String
    var apiKey: String

    static func load() -> AgentSettings {
        let defaults = UserDefaults.standard
        let provider = AgentProviderKind(rawValue: defaults.string(forKey: "agent.provider") ?? "") ?? .anthropic
        let settings = AgentSettings(
            provider: provider,
            model: defaults.string(forKey: "agent.model.\(provider.rawValue)") ?? provider.defaultModel,
            baseURL: defaults.string(forKey: "agent.baseURL") ?? "https://api.openai.com/v1",
            apiKey: Keychain.read(account: provider.rawValue) ?? ""
        )
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if settings.apiKey.isEmpty, let key = env["AGENT_API_KEY"] {
            let provider = AgentProviderKind(rawValue: env["AGENT_PROVIDER"] ?? "") ?? .anthropic
            return AgentSettings(provider: provider, model: env["AGENT_MODEL"] ?? provider.defaultModel, baseURL: env["AGENT_BASE_URL"] ?? settings.baseURL, apiKey: key)
        }
        #endif
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue, forKey: "agent.provider")
        defaults.set(model, forKey: "agent.model.\(provider.rawValue)")
        defaults.set(baseURL, forKey: "agent.baseURL")
        Keychain.write(apiKey, account: provider.rawValue)
    }

    func makeProvider() -> (any AgentProvider)? {
        #if DEBUG
        if ScriptedAgentProvider.isEnabled { return ScriptedAgentProvider() }
        #endif
        guard !apiKey.isEmpty else { return nil }
        switch provider {
        case .anthropic:
            return AnthropicProvider(apiKey: apiKey, model: model)
        case .openai:
            guard let url = URL(string: baseURL) else { return nil }
            return OpenAICompatibleProvider(baseURL: url, apiKey: apiKey, model: model)
        }
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
