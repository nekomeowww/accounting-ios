import SwiftUI
import UIKit

struct AgentSettingsView: View {
    @State private var settings = AgentSettings.load()
    var onSave: () -> Void

    var body: some View {
        Form {
            Section("服务") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(AgentProviderKind.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.provider) { _, provider in
                    settings.model = UserDefaults.standard.string(forKey: "agent.model.\(provider.rawValue)") ?? provider.defaultModel
                    settings.apiKey = Keychain.read(account: provider.rawValue) ?? ""
                }
                TextField("Model", text: $settings.model)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if settings.provider == .openai {
                    TextField("Base URL", text: $settings.baseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !settings.baseURL.isEmpty, !AgentSettings.isAllowedBaseURL(settings.baseURL) {
                        Text("需要 HTTPS 地址；HTTP 仅允许 localhost。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            Section("API Key") {
                SecureField("sk-…", text: $settings.apiKey)
                Text("仅保存在本机 Keychain，不会进入账本或导出文件。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("保存") {
                    settings.save()
                    onSave()
                }
                .disabled(settings.model.isEmpty)
            }
        }
    }
}

final class AgentSettingsViewController: UIHostingController<AgentSettingsView> {
    init() {
        super.init(rootView: AgentSettingsView(onSave: {}))
        title = "AI 设置"
        rootView = AgentSettingsView { [weak self] in self?.navigationController?.popViewController(animated: true) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
