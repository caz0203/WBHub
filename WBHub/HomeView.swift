import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var showLogs = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    heroCard
                    statRow
                    quickPanel
                    creditPanel
                    logPanel
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 26)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("WorkBuddy Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showLogs = true } label: { Image(systemName: "text.alignleft") }
                }
            }
            .sheet(isPresented: $showLogs) { LogView() }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.gradient)
                    .frame(width: 42, height: 42)
                Image(systemName: "cube.transparent.fill")
                    .foregroundStyle(.white)
                    .font(.system(size: 19, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("WorkBuddy Hub")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text(store.snapshotHeader())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Pill(text: store.serverRunning ? "运行中" : "已停止",
                 color: store.serverRunning ? Theme.ok : Theme.err)
        }
        .padding(.top, 4)
    }

    // MARK: - 反代主卡

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本地反代")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                    Text(store.serverRunning ? "监听中 · :\(store.settings.port)" : "已停止")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
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

            VStack(alignment: .leading, spacing: 7) {
                copyLine("Base URL", store.baseURL)
                copyLine("API Key", store.settings.apiKey)
            }

            HStack(spacing: 8) {
                Text(store.settings.defaultModel == "auto" ? "默认模型 auto" : "默认 \(store.settings.defaultModel)")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                    .foregroundStyle(.white)
                if store.settings.promptMode != .off {
                    Text("提示词 \(store.settings.promptMode.label)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                        .foregroundStyle(.white)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.gradient))
    }

    private func copyLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Button {
                UIPasteboard.general.string = value
                store.log("已复制 \(label)", .info)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 统计

    private var statRow: some View {
        HStack(spacing: 10) {
            StatTile(title: "账号", value: "\(store.activeAccounts.count)",
                     hint: store.accounts.count == store.activeAccounts.count
                         ? "全部启用" : "共 \(store.accounts.count) 个",
                     tint: Theme.accent)
            StatTile(title: "总积分", value: fmt(totalCredits), hint: "跨账号合计", tint: Theme.warn)
            StatTile(title: "请求", value: "\(store.requestCount)",
                     hint: store.serverRunning ? "服务中" : "未启动", tint: Theme.accent2)
        }
    }

    // MARK: - 快捷

    private var quickPanel: some View {
        Panel("快捷操作") {
            HStack(spacing: 8) {
                quick("跑任务", "play.fill", Theme.ok) {
                    Task { await TaskRunner.shared.runFromUI(store: store) }
                }
                quick("刷凭证", "key.fill", Theme.accent) {
                    Task {
                        await Upstream.shared.refreshAll()
                        await store.refreshCreditsAsync()
                    }
                }
                quick("夜猫子", "moon.stars.fill", Theme.accent2) {
                    Task {
                        let r = await TaskRunner.shared.runNightWindow()
                        store.currentTasks.append(contentsOf: r.steps)
                        store.log(r.summary, .info)
                    }
                }
                quick("清日志", "trash.fill", Theme.err) {
                    store.clearLogs()
                }
            }
            .padding(12)
        }
    }

    private func quick(_ title: String, _ icon: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.11)))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 积分

    private var creditPanel: some View {
        Panel("账号积分") {
            if topAccounts.isEmpty {
                EmptyHint(icon: "person.crop.circle.badge.questionmark",
                          title: "还没有账号", detail: "去「账号」页扫码登录")
            } else {
                ForEach(Array(topAccounts.enumerated()), id: \.element.id) { index, account in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(account.disabled ? Theme.err : Theme.ok)
                            .frame(width: 6, height: 6)
                        Text(account.displayName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Text(fmt(account.credits))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.warn)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    if index < topAccounts.count - 1 { RowDivider(inset: 30) }
                }
            }
        }
    }

    private var topAccounts: [Account] {
        Array(store.accounts.sorted(by: { $0.credits > $1.credits }).prefix(4))
    }

    private var totalCredits: Double {
        store.accounts.reduce(0) { $0 + $1.credits }
    }

    // MARK: - 日志

    private var logPanel: some View {
        Panel("运行日志") {
            if store.logs.isEmpty {
                Text("暂无日志")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ForEach(Array(store.logs.suffix(5).enumerated()), id: \.element.id) { index, line in
                    HStack(alignment: .top, spacing: 7) {
                        Text(line.stamp)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.7))
                        Text(line.text)
                            .font(.system(size: 11))
                            .foregroundStyle(color(for: line.level))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    if index < min(5, store.logs.count) - 1 { RowDivider(inset: 14) }
                }
                RowDivider(inset: 14)
                Button { showLogs = true } label: {
                    Text("查看全部")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 3) {
            Text("WorkBuddy Hub v\(AppInfo.version)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.7))
            Text("作者 小帅 · QQ \(AppInfo.authorQQ)")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - helpers

    private func color(for level: LogLine.Level) -> Color {
        switch level {
        case .ok: return Theme.ok
        case .warn: return Theme.warn
        case .err: return Theme.err
        case .info: return .primary
        }
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - 日志全屏

struct LogView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var filter: LogLine.Level? = nil

    private var lines: [LogLine] {
        guard let filter = filter else { return store.logs }
        return store.logs.filter { $0.level == filter }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    chip("全部", nil)
                    chip("OK", .ok)
                    chip("WARN", .warn)
                    chip("ERR", .err)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                Divider()
                if lines.isEmpty {
                    Spacer()
                    EmptyHint(icon: "text.alignleft", title: "没有日志", detail: "运行任务或发起请求后会在这里显示")
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(lines) { line in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(line.stamp)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(Color.secondary.opacity(0.7))
                                            .frame(width: 54, alignment: .leading)
                                        Text(line.level.rawValue)
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(color(for: line.level))
                                            .frame(width: 34, alignment: .leading)
                                        Text(line.text)
                                            .font(.system(size: 11))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .id(line.id)
                                    RowDivider(inset: 14)
                                }
                            }
                        }
                        .onAppear {
                            if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .navigationTitle("日志 · \(lines.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { store.clearLogs() }.foregroundStyle(Theme.err)
                }
            }
        }
    }

    private func chip(_ label: String, _ level: LogLine.Level?) -> some View {
        let active = filter == level
        return Button {
            filter = level
        } label: {
            Text(label)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(active ? Theme.accent.opacity(0.16) : Theme.soft))
                .foregroundStyle(active ? Theme.accent : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func color(for level: LogLine.Level) -> Color {
        switch level {
        case .ok: return Theme.ok
        case .warn: return Theme.warn
        case .err: return Theme.err
        case .info: return .primary
        }
    }
}
