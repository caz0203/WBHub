import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var showLogs = false
    @State private var copied = false
    @State private var busy = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    proxyCard
                    statsGrid
                    modelHint
                    quickActions
                    logPreview
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
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

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.gradient)
                    .frame(width: 46, height: 46)
                Image(systemName: "cube.transparent.fill").foregroundStyle(.white).font(.system(size: 21, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("WorkBuddy Hub").font(.system(size: 18, weight: .bold, design: .rounded))
                Text(store.snapshotHeader()).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Pill(text: store.serverRunning ? "运行中" : "已停止",
                 color: store.serverRunning ? Theme.ok : Theme.err)
        }
        .padding(.top, 6)
    }

    private var proxyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("本地反代", systemImage: "network")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.serverRunning },
                        set: { on in
                            Task { @MainActor in
                                if on { await ServerManager.shared.start() } else { ServerManager.shared.stop() }
                            }
                        }))
                        .labelsHidden()
                        .tint(Theme.ok)
                }
                VStack(alignment: .leading, spacing: 8) {
                    row("Base URL", store.baseURL)
                    row("API Key", store.settings.apiKey)
                    row("模型", "\(store.models.count) 个可用 · 默认 \(store.settings.defaultModel)")
                }
                HStack(spacing: 8) {
                    Button {
                        UIPasteboard.general.string = store.baseURL
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_400_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制地址", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)

                    Button {
                        Task { @MainActor in
                            busy = true
                            await ServerManager.shared.reloadModels()
                            await store.refreshCreditsAsync()
                            busy = false
                        }
                    } label: {
                        Label("同步", systemImage: busy ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }
                if !store.models.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(store.models.prefix(12))) { model in
                                Button {
                                    store.updateSettings { $0.defaultModel = model.id }
                                } label: {
                                    Text(model.id)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .padding(.horizontal, 8).padding(.vertical, 5)
                                        .background(Capsule().fill(store.settings.defaultModel == model.id
                                                                   ? Theme.accent.opacity(0.2)
                                                                   : Color.primary.opacity(0.06)))
                                        .foregroundStyle(store.settings.defaultModel == model.id ? Theme.accent : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Text("OpenAI 兼容：/v1/chat/completions · /v1/models     Anthropic：/v1/messages     Responses：/v1/responses")
                    .font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.7))
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatTile(title: "账号", value: "\(store.activeAccounts.count)",
                     hint: "国内 \(store.accounts.filter { $0.realm == .cn && !$0.disabled }.count) · 国际 \(store.accounts.filter { $0.realm == .global && !$0.disabled }.count)")
            StatTile(title: "总积分", value: Int(store.accounts.reduce(0) { $0 + $1.credits }).description,
                     hint: "跨账号合计", tint: Theme.warn)
            StatTile(title: "请求", value: "\(store.requestCount)", hint: "本次运行已代理", tint: Theme.accent2)
            StatTile(title: "任务", value: store.taskRunning ? "运行中" : "空闲",
                     hint: store.accounts.filter { !$0.lastRun.isEmpty }.count.description + " 个账号跑过",
                     tint: store.taskRunning ? Theme.ok : Color.secondary)
        }
    }

    private var topAccounts: [Account] {
        Array(store.accounts.sorted(by: { $0.credits > $1.credits }).prefix(4))
    }

    private var modelHint: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("账号积分", systemImage: "creditcard").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button {
                        Task { @MainActor in await store.refreshCreditsAsync() }
                    } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                }
                if store.accounts.isEmpty {
                    Text("暂无账号").font(.system(size: 12)).foregroundStyle(Color.secondary.opacity(0.7))
                } else {
                    ForEach(topAccounts) { account in
                        HStack(spacing: 8) {
                            Circle().fill(account.disabled ? Theme.err : Theme.ok).frame(width: 6, height: 6)
                            Text(account.displayName).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text("\(Int(account.credits))").font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.warn)
                        }
                    }
                }
            }
        }
    }

    private var quickActions: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("快捷操作", systemImage: "wand.and.stars").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    quick("一键跑任务", "play.fill", Theme.ok) {
                        Task { @MainActor in await TaskRunner.shared.runFromUI(store: store) }
                    }
                    quick("刷新凭证", "key.fill", Theme.accent) {
                        Task { @MainActor in
                            busy = true
                            await Upstream.shared.refreshAll()
                            await store.refreshCreditsAsync()
                            busy = false
                        }
                    }
                    quick("夜猫子", "moon.stars.fill", Theme.accent2) {
                        Task { @MainActor in
                            let r = await TaskRunner.shared.runNightWindow()
                            store.currentTasks = r.steps
                            store.log(r.summary, .info)
                        }
                    }
                }
            }
        }
    }

    private func quick(_ title: String, _ icon: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    private var logPreview: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("运行日志", systemImage: "text.alignleft").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("全部") { showLogs = true }.font(.system(size: 12))
                }
                if store.logs.isEmpty {
                    Text("暂无日志").font(.system(size: 12)).foregroundStyle(Color.secondary.opacity(0.7))
                } else {
                    ForEach(Array(store.logs.suffix(4))) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.stamp).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.secondary.opacity(0.7))
                            Text(line.text).font(.system(size: 11)).lineLimit(2)
                                .foregroundStyle(color(for: line.level))
                            Spacer(minLength: 0)
                        }
                    }
                }
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

    private func color(for level: LogLine.Level) -> Color {
        switch level {
        case .ok: return Theme.ok
        case .warn: return Theme.warn
        case .err: return Theme.err
        case .info: return .primary
        }
    }
}

struct LogView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                List {
                    ForEach(store.logs) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.stamp).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            Text(line.text).font(.system(size: 12)).id(line.id)
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear { if let last = store.logs.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { store.clearLogs() }.foregroundStyle(Theme.err)
                }
            }
        }
    }
}
