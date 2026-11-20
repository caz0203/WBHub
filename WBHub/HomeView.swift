import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var showLogs = false
    @State private var showRequestLogs = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Screen("WorkBuddy Hub", trailing: AnyView(
            Button { showLogs = true } label: {
                Image(systemName: "text.alignleft")
            }
        )) {
            heroCard
            statRow
            quickPanel
            requestPanel
            creditPanel
            logPanel
            footer
        }
        .onAppear { store.refreshLanIP() }
        .onChange(of: scenePhase) { _ in store.refreshLanIP() }
        .sheet(isPresented: $showLogs) { LogView() }
        .sheet(isPresented: $showRequestLogs) { RequestLogView() }
    }

    // MARK: - 主卡

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.serverRunning ? "反代运行中" : "反代已停止")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(":\(store.settings.port)")
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        if store.serverRunning {
                            Circle().fill(Color.white.opacity(0.9))
                                .frame(width: 6, height: 6)
                                .offset(y: -3)
                        }
                    }
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
                    .tint(Color.white.opacity(0.85))
            }

            VStack(spacing: 5) {
                copyLine("本机", store.baseURL)
                if let lan = store.lanBaseURL {
                    copyLine("局域网", lan, tint: Color.white.opacity(0.92))
                } else {
                    HStack(spacing: 7) {
                        Text("局域网")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.68))
                            .frame(width: 44, alignment: .leading)
                        Text("未连接到 Wi-Fi")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.55))
                        Spacer(minLength: 2)
                    }
                }
                copyLine("Key", store.settings.apiKey)
            }

            HStack(spacing: 6) {
                chip(store.settings.defaultModel == "auto" ? "auto" : store.settings.defaultModel)
                if store.settings.promptMode != .off {
                    chip("提示词 \(store.settings.promptMode.label)")
                }
                Spacer()
            }
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Theme.gradient))
    }

    private func copyLine(_ label: String, _ value: String,
                          tint: Color = .white) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.68))
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(tint)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Button {
                UIPasteboard.general.string = value
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.log("已复制 \(label)", .info)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.18)))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    // MARK: - 统计

    private var statRow: some View {
        HStack(spacing: 8) {
            miniStat("账号", "\(store.activeAccounts.count)", Theme.accent,
                     "共 \(store.accounts.count)")
            miniStat("积分", Num.compact(Int(totalCredits)), Theme.warn, "")
            miniStat("请求", "\(store.requestCount)", Theme.accent2,
                     store.serverRunning ? "服务中" : "未启动")
        }
    }

    private func miniStat(_ title: String, _ value: String, _ tint: Color, _ hint: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(Color.secondary.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }

    // MARK: - 快捷

    private var quickPanel: some View {
        Panel("快捷操作") {
            HStack(spacing: 7) {
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
                    }
                }
                quick("清日志", "trash.fill", Theme.err) {
                    store.clearLogs()
                }
            }
            .padding(10)
        }
    }

    private func quick(_ title: String, _ icon: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 9.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.1)))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 请求概览（进入日志）

    private var requestPanel: some View {
        Panel("请求记录") {
            TapRow(action: { showRequestLogs = true }) {
                let s = store.requestSummary()
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                            .fill(Theme.accent.opacity(0.13)).frame(width: 29, height: 29)
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("查看模型调用与消耗")
                            .font(.system(size: 13.5))
                        Text(s.count == 0 ? "还没有请求记录"
                             : "\(s.count) 次 · \(Num.compact(s.tokens)) tokens"
                               + (s.failed > 0 ? " · \(s.failed) 失败" : ""))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.secondary.opacity(0.8))
                    }
                    Spacer()
                    Pill(text: "\(s.count)", color: Theme.accent2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                }
                .padding(.horizontal, Theme.rowPadH)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - 账号积分

    private var creditPanel: some View {
        Panel("账号积分") {
            if topAccounts.isEmpty {
                EmptyHint(icon: "person.crop.circle.badge.questionmark",
                          title: "还没有账号", detail: "去「账号」页扫码登录")
            } else {
                ForEach(Array(topAccounts.enumerated()), id: \.element.id) { index, account in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(account.disabled ? Theme.err : Theme.ok)
                            .frame(width: 5.5, height: 5.5)
                        Text(account.displayName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Text(Num.credit(account.credits))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.warn)
                    }
                    .padding(.horizontal, Theme.rowPadH)
                    .padding(.vertical, 8.5)
                    if index < topAccounts.count - 1 { RowDivider(inset: 28) }
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

    // MARK: - 运行日志

    private var logPanel: some View {
        Panel("运行日志") {
            if store.logs.isEmpty {
                Text("暂无日志")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .padding(Theme.rowPadH)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(store.logs.suffix(4).enumerated()), id: \.element.id) { index, line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(line.stamp)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                        Text(line.text)
                            .font(.system(size: 10.5))
                            .foregroundStyle(color(for: line.level))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.rowPadH)
                    .padding(.vertical, 6.5)
                    if index < min(4, store.logs.count) - 1 { RowDivider() }
                }
                RowDivider()
                TapRow(action: { showLogs = true }) {
                    Text("查看全部")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Text("WorkBuddy Hub v\(AppInfo.version)")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.6))
            Text("作者 小帅 · QQ \(AppInfo.authorQQ)")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
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

// MARK: - 运行日志全屏

struct LogView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var filter: LogLine.Level? = nil
    @State private var showClear = false

    private var lines: [LogLine] {
        guard let filter = filter else { return store.logs }
        return store.logs.filter { $0.level == filter }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    chip("全部", nil)
                    chip("OK", .ok)
                    chip("WARN", .warn)
                    chip("ERR", .err)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider().opacity(0.5)

                if lines.isEmpty {
                    Spacer()
                    EmptyHint(icon: "text.alignleft", title: "没有日志",
                              detail: "运行任务或发起请求后会显示在这里")
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                HStack(alignment: .top, spacing: 7) {
                                    Text(line.stamp)
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundStyle(Color.secondary.opacity(0.6))
                                        .frame(width: 50, alignment: .leading)
                                    Text(line.level.rawValue)
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(color(for: line.level))
                                        .frame(width: 30, alignment: .leading)
                                    Text(line.text)
                                        .font(.system(size: 10.5))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 5.5)
                                RowDivider()
                            }
                        }
                    }
                }
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("日志 · \(lines.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showClear = true } label: { Image(systemName: "trash") }
                        .foregroundStyle(Theme.err)
                        .disabled(store.logs.isEmpty)
                }
            }
            .alert("清空运行日志？", isPresented: $showClear) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) { store.clearLogs() }
            }
        }
    }

    private func chip(_ label: String, _ level: LogLine.Level?) -> some View {
        let active = filter == level
        return Button {
            filter = level
        } label: {
            Text(label)
                .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(active ? Theme.accent.opacity(0.15) : Theme.soft))
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
