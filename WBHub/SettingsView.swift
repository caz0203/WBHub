import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var portText = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("状态")
                        Spacer()
                        Text(store.serverRunning ? "运行中" : "已停止")
                            .foregroundStyle(store.serverRunning ? Theme.ok : Color.secondary)
                    }
                    HStack {
                        Text("地址")
                        Spacer()
                        Text(store.baseURL).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Toggle("启动时自动开反代", isOn: binding(\.autoStart))
                    Toggle("要求 API Key", isOn: binding(\.requireAuth))
                    HStack {
                        Text("API Key")
                        Spacer()
                        Text(store.settings.apiKey)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Button {
                            store.updateSettings { $0.apiKey = "sk-" + Hashing.randomHex(12) }
                        } label: { Image(systemName: "arrow.clockwise") }
                    }
                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("8788", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onSubmit { applyPort() }
                    }
                } header: { Text("反代") }

                Section {
                    Picker("默认模型", selection: binding(\.defaultModel)) {
                        Text("auto").tag("auto")
                        ForEach(store.models) { model in
                            Text(model.id).tag(model.id)
                        }
                    }
                    Stepper("重试次数：\(store.settings.retries)", value: binding(\.retries), in: 0...5)
                    Toggle("Anthropic /v1/messages", isOn: binding(\.enableAnthropic))
                    Toggle("Responses /v1/responses", isOn: binding(\.enableResponses))
                    Toggle("强制 stream_options.include_usage", isOn: binding(\.forceStreamOptions))
                } header: { Text("模型与协议") }

                Section {
                    Toggle("每日自动跑任务", isOn: binding(\.autoTask))
                    HStack {
                        Text("执行时间")
                        Spacer()
                        Picker("小时", selection: binding(\.taskHour)) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }.pickerStyle(.menu)
                        Picker("分钟", selection: binding(\.taskMinute)) {
                            ForEach([0, 5, 10, 15, 20, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                        }.pickerStyle(.menu)
                    }
                    Toggle("夜间 23:00 上报夜猫子", isOn: binding(\.nightTask))
                    Toggle("后台保活（切后台不断线）", isOn: binding(\.backgroundKeepAlive))
                        .onChange(of: store.settings.backgroundKeepAlive) { value in
                            Task { @MainActor in KeepAlive.shared.sync(enabled: value) }
                        }
                } header: { Text("自动化") }

                Section {
                    TextField("国内 chatBase 覆盖（留空用官方）", text: binding(\.cnBaseOverride))
                        .textInputAutocapitalization(.never)
                    TextField("国际 chatBase 覆盖", text: binding(\.globalBaseOverride))
                        .textInputAutocapitalization(.never)
                } header: { Text("上游地址") } footer: {
                    Text("只在自建中转时填写，留空走官方 copilot.tencent.com / www.workbuddy.ai。")
                        .font(.system(size: 10))
                }

                Section {
                    Button {
                        Task { @MainActor in await ServerManager.shared.reloadModels() }
                    } label: { Label("重新拉取模型目录", systemImage: "arrow.triangle.2.circlepath") }
                    Button {
                        Task { @MainActor in await ServerManager.shared.restart() }
                    } label: { Label("重启反代", systemImage: "power") }
                    Button(role: .destructive) {
                        Task { @MainActor in await Upstream.shared.refreshAll(); await store.refreshCreditsAsync() }
                    } label: { Label("刷新全部凭证", systemImage: "key") }
                } header: { Text("维护") }

                Section {
                    HStack {
                        Text("作者"); Spacer(); Text(AppInfo.author).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("QQ")
                        Spacer()
                        Text(AppInfo.authorQQ).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    HStack {
                        Text("版本"); Spacer(); Text("v\(AppInfo.version)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("开源参考")
                        Spacer()
                        Text("workbuddy2api 等").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } header: { Text("关于") }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 2) {
                    Text("WorkBuddy Hub v\(AppInfo.version)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text("作者：小帅　QQ：\(AppInfo.authorQQ)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { portText = String(store.settings.port) }
        }
    }

    @MainActor private func binding<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: keyPath] },
                set: { value in store.updateSettings { $0[keyPath: keyPath] = value } })
    }

    @MainActor private func applyPort() {
        if let value = Int(portText), value > 1024, value < 65535 {
            store.updateSettings { $0.port = value }
            if store.serverRunning { Task { @MainActor in await ServerManager.shared.restart() } }
        } else {
            portText = String(store.settings.port)
        }
    }
}
