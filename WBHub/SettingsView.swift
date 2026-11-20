import SwiftUI
import UIKit

/// 设置页：反代 / 模型入口 / 提示词 / 自动化 / 上游地址 / 维护 / 关于。
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var portText = ""
    @State private var promptDraft = ""
    @State private var promptDirty = false
    @State private var showPromptEditor = false
    @State private var busy = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    proxyPanel
                    modelPanel
                    promptPanel
                    automationPanel
                    upstreamPanel
                    maintenancePanel
                    aboutPanel
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
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
            .onAppear {
                portText = String(store.settings.port)
                if promptDraft.isEmpty { promptDraft = store.settings.promptText }
            }
            .sheet(isPresented: $showPromptEditor) {
                PromptEditorView(draft: $promptDraft, dirty: $promptDirty)
            }
        }
    }

    // MARK: - 反代

    private var proxyPanel: some View {
        Panel("反代") {
            InfoRow("运行状态", subtitle: store.serverRunning ? "监听 \(store.settings.port)" : "未启动",
                icon: "dot.radiowaves.left.and.right",
                iconTint: store.serverRunning ? Theme.ok : Color.secondary) {
                Toggle("", isOn: Binding(
                    get: { store.serverRunning },
                    set: { value in
                        Task { @MainActor in
                            if value { await ServerManager.shared.start() }
                            else { ServerManager.shared.stop() }
                        }
                    }))
                    .labelsHidden()
                    .tint(Theme.ok)
            }
            RowDivider(inset: 55)
            CopyField(label: "Base URL", value: store.baseURL)
            RowDivider(inset: 55)
            CopyField(label: "API Key", value: store.settings.apiKey)
            RowDivider(inset: 55)
            HStack(spacing: 10) {
                Text("端口").font(.system(size: 13))
                Spacer()
                TextField("8788", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 78)
                    .onSubmit { applyPort() }
                Button("应用") { applyPort() }
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            RowDivider()
            toggleRow("启动时自动开反代", \.autoStart)
            RowDivider()
            toggleRow("要求 API Key", \.requireAuth)
            RowDivider()
            HStack(spacing: 10) {
                Text("重置 Key").font(.system(size: 13))
                Spacer()
                Button {
                    store.updateSettings { $0.apiKey = "sk-" + Hashing.randomHex(12) }
                    store.log("API Key 已重置", .ok)
                } label: {
                    Text("重新生成").font(.system(size: 12, weight: .medium))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
        }
    }

    // MARK: - 模型入口

    private var modelPanel: some View {
        Panel("模型", note: "模型列表、上下文长度、倍率与默认模型都在独立页面管理。") {
            NavigationLink {
                ModelsView()
            } label: {
                InfoRow("模型管理", subtitle: currentModelSummary, icon: "cube.transparent", showChevron: true) {
                    Pill(text: "\(store.models.count)", color: Theme.accent2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowDivider(inset: 55)
            toggleRow("Anthropic /v1/messages", \.enableAnthropic)
            RowDivider(inset: 55)
            toggleRow("Responses /v1/responses", \.enableResponses)
        }
    }

    private var currentModelSummary: String {
        let m = store.settings.defaultModel
        return m.isEmpty || m == "auto" ? "默认 auto · 已加载 \(store.models.count) 个" : "默认 \(m)"
    }

    // MARK: - 提示词

    private var promptPanel: some View {
        Panel("系统提示词", note: "出站改写：把自定义规则注入 system 消息，只影响发往上游的请求。") {
            HStack {
                Text("模式").font(.system(size: 13))
                Spacer()
                SegmentedBar(items: promptModeItems,
                             selection: Binding(
                                get: { store.settings.promptMode },
                                set: { value in store.updateSettings { $0.promptMode = value } }))
                    .frame(width: 240)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            RowDivider()
            Button { showPromptEditor = true } label: {
                InfoRow("编辑提示词",
                    subtitle: store.settings.promptText.isEmpty
                        ? "未设置"
                        : "\(store.settings.promptText.count) 字符 · \(firstLine(store.settings.promptText))",
                    icon: "text.quote", showChevron: true) { EmptyView() }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowDivider(inset: 55)
            toggleRow("规避上游客户端标记", \.disguise)
            RowDivider(inset: 55)
            HStack(spacing: 8) {
                Text("已启用预设")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(Presets.alternatives, id: \.title) { preset in
                        Button(preset.title) {
                            promptDraft = preset.body
                            store.updateSettings { $0.promptText = preset.body }
                            store.log("已套用预设：\(preset.title)", .ok)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("套用").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
        }
    }

    private var promptModeItems: [(PromptMode, String)] {
        PromptMode.allCases.map { mode -> (PromptMode, String) in (mode, shortLabel(mode)) }
    }

    private func shortLabel(_ mode: PromptMode) -> String {
        switch mode {
        case .off: return "关闭"
        case .append: return "追加"
        case .prepend: return "前置"
        case .replace: return "替换"
        }
    }

    private func firstLine(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).first ?? ""
        return line.isEmpty ? text : line
    }

    // MARK: - 自动化

    private var automationPanel: some View {
        Panel("自动化") {
            toggleRow("每日自动跑任务", \.autoTask)
            RowDivider()
            HStack {
                Text("执行时间").font(.system(size: 13))
                Spacer()
                Picker("", selection: binding(\.taskHour)) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                Text(":").foregroundStyle(.secondary)
                Picker("", selection: binding(\.taskMinute)) {
                    ForEach([0, 5, 10, 15, 20, 30, 45], id: \.self) {
                        Text(String(format: "%02d", $0)).tag($0)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            RowDivider()
            toggleRow("夜间 23:05 上报夜猫子", \.nightTask)
            RowDivider()
            toggleRow("后台保活（切后台不断线）", \.backgroundKeepAlive)
                .onChange(of: store.settings.backgroundKeepAlive) { value in
                    Task { @MainActor in KeepAlive.shared.sync(enabled: value) }
                }
        }
    }

    // MARK: - 上游

    private var upstreamPanel: some View {
        Panel("上游地址覆盖",
              note: "只在自建中转时填写，留空走官方 copilot.tencent.com / www.workbuddy.ai。") {
            fieldRow("国内", text: binding(\.cnBaseOverride), placeholder: "https://copilot.tencent.com")
            RowDivider()
            fieldRow("国际", text: binding(\.globalBaseOverride), placeholder: "https://www.workbuddy.ai")
        }
    }

    private func fieldRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 13)).frame(width: 42, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.system(size: 11, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    // MARK: - 维护

    private var maintenancePanel: some View {
        Panel("维护") {
            actionRow("重新拉取模型目录", "arrow.triangle.2.circlepath") {
                Task { @MainActor in await ServerManager.shared.reloadModels() }
            }
            RowDivider(inset: 55)
            actionRow("重启反代", "power") {
                Task { @MainActor in await ServerManager.shared.restart() }
            }
            RowDivider(inset: 55)
            actionRow("刷新全部凭证", "key") {
                Task { @MainActor in
                    busy = true
                    await Upstream.shared.refreshAll()
                    await store.refreshCreditsAsync()
                    busy = false
                }
            }
            RowDivider(inset: 55)
            actionRow("清空日志", "trash", tint: Theme.err) {
                store.clearLogs()
            }
        }
    }

    private func actionRow(_ title: String, _ icon: String, tint: Color = Theme.accent,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.14)).frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                }
                Text(title).font(.system(size: 13))
                Spacer()
                if busy && title.contains("刷新") { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 关于

    private var aboutPanel: some View {
        Panel("关于") {
            InfoRow("作者", subtitle: AppInfo.author, icon: "person.crop.circle")
            RowDivider(inset: 55)
            InfoRow("QQ", subtitle: AppInfo.authorQQ, icon: "message")
            RowDivider(inset: 55)
            InfoRow("版本", subtitle: "v\(AppInfo.version)", icon: "tag")
            RowDivider(inset: 55)
            InfoRow("开源参考", subtitle: "workbuddy2api · WorkBuddy-Hub-Android · WorkBuddy-Daily",
                icon: "book")
        }
    }

    // MARK: - 通用

    private func toggleRow(_ title: String, _ keyPath: WritableKeyPath<Settings, Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: binding(keyPath)).labelsHidden().tint(Theme.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    @MainActor private func binding<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: keyPath] },
                set: { value in store.updateSettings { $0[keyPath: keyPath] = value } })
    }

    @MainActor private func applyPort() {
        guard let value = Int(portText), value > 1024, value < 65535 else {
            portText = String(store.settings.port)
            return
        }
        store.updateSettings { $0.port = value }
        store.log("端口改为 \(value)", .ok)
        if store.serverRunning { Task { @MainActor in await ServerManager.shared.restart() } }
    }
}

// MARK: - 提示词编辑器（全屏）

struct PromptEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: String
    @Binding var dirty: Bool
    @State private var copied = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("\(draft.count) 字符")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(Presets.alternatives, id: \.title) { preset in
                            Button(preset.title) { draft = preset.body; dirty = true }
                        }
                    } label: {
                        Label("预设", systemImage: "wand.and.stars").font(.system(size: 12))
                    }
                    Button {
                        UIPasteboard.general.string = draft
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: "doc.on.doc").font(.system(size: 12))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)

                Divider()

                TextEditor(text: $draft)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(12)
                    .onChange(of: draft) { _ in dirty = true }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        draft = Intake.sanitize(draft)
                        dirty = true
                    } label: {
                        Label("整理格式", systemImage: "text.alignleft").font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    Button {
                        draft = ""; dirty = true
                    } label: {
                        Label("清空", systemImage: "trash").font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.err)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .navigationTitle("系统提示词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        store.updateSettings { $0.promptText = draft }
                        store.log("系统提示词已保存（\(store.settings.promptMode.label)）", .ok)
                        dirty = false
                        dismiss()
                    }
                    .font(.body.bold())
                }
            }
        }
    }
}

/// 提示词文本整理：去多余空行、行尾空白。
enum Intake {
    static func sanitize(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: "\u{00A0}", with: " ")
              .trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        var blank = 0
        for line in lines {
            if line.isEmpty {
                blank += 1
                if blank <= 1 { out.append("") }
            } else {
                blank = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
