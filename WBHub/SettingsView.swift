import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var portText = ""
    @State private var showPromptEditor = false
    @State private var showRequestLogs = false
    @State private var showClearLogs = false
    @State private var showClearReqLogs = false
    @State private var busy = false

    var body: some View {
        Screen("设置") {
            proxyPanel
            modelPanel
            promptPanel
            automationPanel
            logPanel
            upstreamPanel
            maintenancePanel
            aboutPanel
        }
        .sheet(isPresented: $showPromptEditor) { PromptEditorView() }
        .sheet(isPresented: $showRequestLogs) { RequestLogView() }
        .onAppear {
            portText = String(store.settings.port)
            KeepAlive.shared.sync(enabled: store.settings.backgroundKeepAlive, mode: store.settings.keepAliveMode)
        }
    }

    // MARK: - 反代

    private var proxyPanel: some View {
        Panel("反代") {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .fill((store.serverRunning ? Theme.ok : Color.secondary).opacity(0.13))
                        .frame(width: 29, height: 29)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(store.serverRunning ? Theme.ok : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("运行状态").font(.system(size: 14))
                    Text(store.serverRunning ? "监听 :\(store.settings.port)" : "未启动")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                }
                Spacer()
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
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, 10)

            RowDivider(inset: 54)
            CopyField(label: "Base URL", value: store.baseURL)
            RowDivider(inset: 54)
            CopyField(label: "API Key", value: store.settings.apiKey) {
                store.log("API Key 已复制", .info)
            }
            RowDivider(inset: 54)
            HStack(spacing: 8) {
                Text("端口").font(.system(size: 13.5))
                Spacer()
                TextField("8788", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 70)
                Button("应用") { applyPort() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, 9)

            RowDivider(inset: 54)
            toggleRow("启动时自动开反代", \.autoStart)
            RowDivider(inset: 54)
            toggleRow("要求 API Key", \.requireAuth)
            RowDivider(inset: 54)
            TapRow(action: {
                store.updateSettings { $0.apiKey = "sk-" + Hashing.randomHex(12) }
                store.log("API Key 已重置", .ok)
            }) {
                InfoRow("重置 API Key", subtitle: "生成新的随机 Key，旧 Key 立即失效",
                        icon: "key", destructive: false) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    // MARK: - 模型

    private var modelPanel: some View {
        Panel("模型") {
            TapRow(action: {}) {
                NavigationLink {
                    ModelsView()
                } label: {
                    InfoRow("模型管理", subtitle: modelSummary,
                            icon: "cube.transparent", showChevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
            }
            RowDivider(inset: 54)
            toggleRow("Anthropic /v1/messages", \.enableAnthropic)
            RowDivider(inset: 54)
            toggleRow("Responses /v1/responses", \.enableResponses)
        }
    }

    private var keepAlive: (ok: Bool, text: String) {
        let k = KeepAlive.shared
        if !store.settings.backgroundKeepAlive { return (false, "关闭时切后台约 30 秒后连接会断") }
        return (k.active, k.active ? k.detail : "尚未生效：\(k.detail)")
    }

    private var keepAliveDetail: String { keepAlive.text }

    private var modelSummary: String {
        let m = store.settings.defaultModel
        let base = (m.isEmpty || m == "auto") ? "默认 auto" : "默认 \(m)"
        return "\(base) · 共 \(store.models.count) 个"
    }

    // MARK: - 提示词

    private var promptPanel: some View {
        Panel("系统提示词", note: "出站改写：把规则注入 system 消息，只影响发往上游的请求，不改客户端。") {
            HStack {
                Text("模式").font(.system(size: 13.5))
                Spacer()
                SegmentedBar(items: promptModeItems, selection: Binding(
                    get: { store.settings.promptMode },
                    set: { v in store.updateSettings { $0.promptMode = v } }))
                    .frame(width: 220)
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, 9)

            RowDivider(inset: 54)
            TapRow(action: { showPromptEditor = true }) {
                InfoRow("编辑提示词", subtitle: promptSummary,
                        icon: "text.quote", showChevron: true) { EmptyView() }
            }
            RowDivider(inset: 54)
            toggleRow("规避上游客户端标记", \.disguise)
            RowDivider(inset: 54)
            HStack(spacing: 6) {
                Text("快速套用").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(Presets.alternatives, id: \.title) { preset in
                        Button(preset.title) {
                            store.updateSettings { $0.promptText = preset.body }
                            store.log("已套用预设：\(preset.title)", .ok)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "wand.and.stars").font(.system(size: 10))
                        Text("预设").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, 9)
        }
    }

    private var promptModeItems: [(PromptMode, String)] {
        PromptMode.allCases.map { mode -> (PromptMode, String) in (mode, shortLabel(mode)) }
    }

    private var promptSummary: String {
        let t = store.settings.promptText
        if t.isEmpty { return "未设置" }
        let first = t.components(separatedBy: .newlines).first ?? t
        return "\(t.count) 字符 · \(first)"
    }

    private func shortLabel(_ mode: PromptMode) -> String {
        switch mode {
        case .off: return "关闭"
        case .append: return "追加"
        case .prepend: return "前置"
        case .replace: return "替换"
        }
    }

    // MARK: - 自动化

    private var automationPanel: some View {
        Panel("自动化") {
            toggleRow("每日自动跑任务", \.autoTask)
            RowDivider(inset: 54)
            HStack {
                Text("执行时间").font(.system(size: 13.5))
                Spacer()
                Picker("", selection: binding(\.taskHour)) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                Text(":").foregroundStyle(Color.secondary.opacity(0.6))
                Picker("", selection: binding(\.taskMinute)) {
                    ForEach([0, 5, 10, 15, 20, 30, 45], id: \.self) {
                        Text(String(format: "%02d", $0)).tag($0)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, 5)
            RowDivider(inset: 54)
            toggleRow("夜间 23:05 上报夜猫子", \.nightTask)
            RowDivider(inset: 54)
            HStack {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("后台保活").font(.system(size: 13.5))
                    Text(keepAliveDetail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(keepAliveColor)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.settings.backgroundKeepAlive },
                    set: { value in
                        store.updateSettings { $0.backgroundKeepAlive = value }
                        Task { @MainActor in
                            KeepAlive.shared.sync(enabled: value, mode: store.settings.keepAliveMode)
                        }
                    }))
                    .labelsHidden()
                    .tint(Theme.accent)
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, 6)

            if store.settings.backgroundKeepAlive {
                RowDivider(inset: 54)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("保活方式").font(.system(size: 13.5))
                        Spacer()
                        Text(store.settings.keepAliveMode.cost)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary.opacity(0.8))
                    }
                    SegmentedBar(items: keepAliveItems, selection: Binding(
                        get: { store.settings.keepAliveMode },
                        set: { v in
                            store.updateSettings { $0.keepAliveMode = v }
                            Task { @MainActor in
                                KeepAlive.shared.sync(enabled: store.settings.backgroundKeepAlive, mode: v)
                            }
                        }))
                    Text(store.settings.keepAliveMode.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.rowPadH)
                .padding(.vertical, 9)

                RowDivider(inset: 54)
                HStack(spacing: 6) {
                    Circle()
                        .fill(KeepAlive.shared.audioOn ? Theme.ok : Color.secondary.opacity(0.4))
                        .frame(width: 5.5, height: 5.5)
                    Text(KeepAlive.shared.audioOn ? "音频会话已建立" : "音频会话未建立")
                        .font(.system(size: 10.5))
                        .foregroundStyle(KeepAlive.shared.audioOn ? Theme.ok : Color.secondary.opacity(0.8))
                    Spacer()
                    if KeepAlive.shared.uptime > 0 {
                        Text("已运行 \(keepAliveUptime)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.75))
                    }
                    if KeepAlive.shared.renewCount > 0 {
                        Text("续期 \(KeepAlive.shared.renewCount)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.75))
                    }
                }
                .padding(.horizontal, Theme.rowPadH)
                .padding(.vertical, 8)
            }
        }
    }

    private var keepAliveItems: [(KeepAliveMode, String)] {
        KeepAliveMode.allCases.map { m -> (KeepAliveMode, String) in (m, m.label) }
    }

    private var keepAliveUptime: String {
        let s = KeepAlive.shared.uptime
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\(s % 3600 / 60)m"
    }

    private var keepAliveColor: Color {
        if !store.settings.backgroundKeepAlive { return Color.secondary.opacity(0.8) }
        if KeepAlive.shared.degraded { return Theme.warn }
        return KeepAlive.shared.active ? Theme.ok : Color.secondary.opacity(0.8)
    }

    // MARK: - 日志

    private var logPanel: some View {
        Panel("日志") {
            TapRow(action: { showRequestLogs = true }) {
                let s = store.requestSummary()
                InfoRow("请求日志",
                        subtitle: s.count == 0 ? "未记录" : "\(s.count) 次 · \(Num.compact(s.tokens)) tokens",
                        icon: "arrow.up.arrow.down", showChevron: true) {
                    Pill(text: "\(s.count)", color: Theme.accent2)
                }
            }
            RowDivider(inset: 54)
            TapRow(action: { showClearReqLogs = true }) {
                InfoRow("清空请求日志", subtitle: "\(store.requestLogs.count) 条",
                        icon: "trash", destructive: true) { EmptyView() }
            }
            .disabled(store.requestLogs.isEmpty)
            RowDivider(inset: 54)
            TapRow(action: { showClearLogs = true }) {
                InfoRow("清空运行日志", subtitle: "\(store.logs.count) 条",
                        icon: "trash", destructive: true) { EmptyView() }
            }
            .disabled(store.logs.isEmpty)
            .alert("清空请求日志？", isPresented: $showClearReqLogs) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { store.clearRequestLogs() }
            }
            .alert("清空运行日志？", isPresented: $showClearLogs) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { store.clearLogs() }
            }
        }
    }

    // MARK: - 上游

    private var upstreamPanel: some View {
        Panel("上游地址覆盖", note: "只在自建中转时填写，留空走官方域名。") {
            fieldRow("国内", text: binding(\.cnBaseOverride), placeholder: "https://copilot.tencent.com")
            RowDivider(inset: 54)
            fieldRow("国际", text: binding(\.globalBaseOverride), placeholder: "https://www.workbuddy.ai")
        }
    }

    private func fieldRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 9) {
            Text(label).font(.system(size: 13.5)).frame(width: 32, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.system(size: 10.5, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Theme.rowPadH)
        .padding(.vertical, 10)
    }

    // MARK: - 维护

    private var maintenancePanel: some View {
        Panel("维护") {
            actionRow("重新拉取模型目录", "arrow.triangle.2.circlepath") {
                Task { @MainActor in await ServerManager.shared.reloadModels() }
            }
            RowDivider(inset: 54)
            actionRow("重启反代", "power") {
                Task { @MainActor in await ServerManager.shared.restart() }
            }
            RowDivider(inset: 54)
            actionRow("刷新全部凭证", "key", busy: busy) {
                Task { @MainActor in
                    busy = true
                    await Upstream.shared.refreshAll()
                    await store.refreshCreditsAsync()
                    busy = false
                }
            }
        }
    }

    private func actionRow(_ title: String, _ icon: String, tint: Color = Theme.accent,
                           busy: Bool = false, action: @escaping () -> Void) -> some View {
        TapRow(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .fill(tint.opacity(0.13)).frame(width: 29, height: 29)
                    Image(systemName: icon)
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(tint)
                }
                Text(title).font(.system(size: 13.5))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, 9)
        }
    }

    // MARK: - 关于

    private var aboutPanel: some View {
        Panel("关于") {
            InfoRow("作者", subtitle: "\(AppInfo.author)　QQ \(AppInfo.authorQQ)",
                    icon: "person.crop.circle") {
                Button {
                    UIPasteboard.general.string = AppInfo.authorQQ
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.log("已复制 QQ", .info)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            RowDivider(inset: 54)
            InfoRow("版本", subtitle: "v\(AppInfo.version)", icon: "tag") { EmptyView() }
        }
    }

    // MARK: - 通用

    private func toggleRow(_ title: String, _ keyPath: WritableKeyPath<Settings, Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 13.5))
            Spacer()
            Toggle("", isOn: binding(keyPath)).labelsHidden().tint(Theme.accent)
        }
        .padding(.horizontal, Theme.rowPadH)
        .padding(.vertical, 5)
    }

    @MainActor private func binding<T>(_ keyPath: WritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: keyPath] },
                set: { v in store.updateSettings { $0[keyPath: keyPath] = v } })
    }

    @MainActor private func applyPort() {
        guard let v = Int(portText), v > 1024, v < 65535 else {
            portText = String(store.settings.port)
            return
        }
        store.updateSettings { $0.port = v }
        store.log("端口改为 \(v)", .ok)
        if store.serverRunning { Task { @MainActor in await ServerManager.shared.restart() } }
    }
}

// MARK: - 提示词编辑器

struct PromptEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var copied = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("\(draft.count) 字符")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                    Spacer()
                    Menu {
                        ForEach(Presets.alternatives, id: \.title) { preset in
                            Button(preset.title) { draft = preset.body }
                        }
                    } label: {
                        Label("预设", systemImage: "wand.and.stars").font(.system(size: 11.5))
                    }
                    Button {
                        UIPasteboard.general.string = draft
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11.5))
                    }
                }
                .padding(.horizontal, 15).padding(.vertical, 9)

                Divider().opacity(0.5)

                TextEditor(text: $draft)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(11)

                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    Button {
                        draft = Intake.sanitize(draft)
                    } label: {
                        Label("整理", systemImage: "text.alignleft").font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                    Button {
                        draft = ""
                    } label: {
                        Label("清空", systemImage: "trash").font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.err)
                    Spacer()
                }
                .padding(.horizontal, 15).padding(.vertical, 9)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("系统提示词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        store.updateSettings { $0.promptText = draft }
                        store.log("提示词已保存（\(store.settings.promptMode.label)）", .ok)
                        dismiss()
                    }
                    .font(.body.bold())
                }
            }
            .onAppear { draft = store.settings.promptText }
        }
    }
}

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
