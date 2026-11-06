import SwiftUI

struct SettingsView: View {
    var sourcesOnly = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @AppStorage("afmc.theme") private var theme = "system"

    var body: some View {
        NavigationStack {
            List {
                if sourcesOnly {
                Section("已添加搜索源") {
                    ForEach($model.sources) { $source in
                        Toggle(isOn: $source.enabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text(source.kind.label + (source.endpoint.isEmpty ? "" : " · " + source.endpoint))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if !source.note.isEmpty {
                                    Text(source.note)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        model.sources.remove(atOffsets: offsets)
                    }
                    Button("添加搜索源") { showAdd = true }
                }

                } else {
                Section("搜索偏好") {
                    Toggle("中文资源优先", isOn: $model.preferChineseResults)
                    Text("用于“推荐”排序：同等匹配与近期播放表现下，优先国语、中文字幕和已识别的中文搜索源。按大小、日期等排序时，以所选排序为准；明确搜索外语或原声时不额外加权。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("外观") {
                    Picker("主题", selection: $theme) {
                        Text("跟随系统").tag("system")
                        Text("深色").tag("dark")
                        Text("浅色").tag("light")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    NavigationLink("连接电脑（高级）") {
                        HostPlaybackSettingsView().environmentObject(model)
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    Text("AFMC FIND 只聚合你自己配置的搜索源，不托管、不分发任何内容。磁力默认由手机内置引擎处理。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                }
            }
            .navigationTitle(sourcesOnly ? "搜索源" : "设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddSourceView { source in
                    model.sources.append(source)
                }
            }
        }
        .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)
        .sensoryFeedback(.selection, trigger: theme)
        .sensoryFeedback(.selection, trigger: model.preferChineseResults)
    }
}

private struct HostPlaybackSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("使用电脑辅助播放", isOn: Binding(
                    get: { !model.useEmbeddedEngine },
                    set: { model.useEmbeddedEngine = !$0 }
                ))
            } footer: {
                Text("默认由手机独立播放，无需设置。仅在你已部署电脑播放服务、希望借助电脑时开启。")
            }
            if !model.useEmbeddedEngine {
                Section("电脑播放服务") {
                    TextField("服务地址，如 http://192.168.1.10:8765", text: $model.hostURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("访问令牌（可选）", text: $model.hostToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(model.isTestingHost ? "测试中…" : "测试连接") {
                        Task { await model.testHost() }
                    }.disabled(model.isTestingHost || model.hostURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let message = model.hostTestMessage {
                        Text(message).font(.footnote)
                            .foregroundStyle(message.hasPrefix("连接成功") ? AppPalette.accent : Color.red)
                    }
                    Button("播放极空间测试片") { model.requestLibraryPlayback() }
                        .disabled(model.hostURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section {
                    Text("电脑需运行 AFMC 配套播放服务，手机需能访问该电脑地址。这不是搜索网站地址，也不是 Jackett 地址。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("连接电脑")
    }
}

extension AddSourceView {
    func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let candidates = try await WebsiteDiscovery.discover(endpoint, useBrowser: useBrowser)
            guard let first = candidates.first else {
                discoveryMessage = "没有发现搜索表单，请手动填写模板"
                return
            }
            endpoint = first.template
            discoveryMessage = "已填入：\(first.template)"
        } catch {
            discoveryMessage = error.localizedDescription
        }
    }

    func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let config = SourceConfig(name: name.isEmpty ? "测试源" : name, kind: kind,
                                  endpoint: endpoint, apiKey: apiKey)
        do {
            let count: Int
            if kind == .torznab {
                count = try await TorznabSource.test(config)
            } else if kind == .archive {
                count = try await ArchiveSource.search(query: "test").count
            } else if kind == .website {
                count = try await SearchSourceClient.search(config, query: "test").count
            } else {
                count = 0
            }
            testMessage = "连接成功 · 示例查询返回 \(count) 条"
        } catch {
            testMessage = error.localizedDescription
        }
    }
}

struct AddSourceView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (SourceConfig) -> Void

    @State private var name = ""
    @State private var kind: SourceKind = .torznab
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var testMessage: String?
    @State private var isTesting = false
    @State private var isDiscovering = false
    @State private var discoveryMessage: String?
    @State private var useBrowser = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                    Picker("类型", selection: $kind) {
                        ForEach([SourceKind.torznab, .archive, .website]) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    if kind == .piratebay {
                        Text("使用 apibay.org 公开接口，无需地址与密钥。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("地址", text: $endpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    if kind == .website {
                        Toggle("用浏览器渲染（JS 站点）", isOn: $useBrowser)
                        Button {
                            Task { await discover() }
                        } label: {
                            HStack {
                                Text(isDiscovering ? "探测中…" : "自动探测搜索入口")
                                if isDiscovering { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(endpoint.trimmingCharacters(in: .whitespaces).isEmpty || isDiscovering)
                        if let discoveryMessage {
                            Text(discoveryMessage)
                                .font(.footnote)
                                .foregroundStyle(discoveryMessage.hasPrefix("已填入") ? AppPalette.accent : Color.secondary)
                        }
                        Text("也可以直接填搜索页模板，用 {q} 或 {query} 代表关键词。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if kind == .torznab {
                        TextField("API Key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("仅用于你自己部署的 Jackett 等搜索服务：填写该服务提供的 Torznab 地址和 API Key。使用已有搜索源无需填写。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if kind != .piratebay {
                    Section {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            HStack {
                                Text(isTesting ? "测试中…" : "测试连接")
                                if isTesting { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(endpoint.trimmingCharacters(in: .whitespaces).isEmpty || isTesting)
                        if let testMessage {
                            Text(testMessage)
                                .font(.footnote)
                                .foregroundStyle(testMessage.hasPrefix("连接成功") ? AppPalette.accent : Color.red)
                        }
                    }
                }
            }
            .navigationTitle("添加搜索源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let finalEndpoint = kind == .piratebay ? "https://apibay.org" : endpoint
                        onSave(SourceConfig(name: name, kind: kind, endpoint: finalEndpoint,
                                            apiKey: apiKey, useBrowser: kind == .website ? useBrowser : false))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (kind != .piratebay && endpoint.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }
}
