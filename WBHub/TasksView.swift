import SwiftUI

struct TasksView: View {
    @EnvironmentObject var store: AppStore
    @State private var showNight = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    if !store.lastError.isEmpty {
                        Card {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                                Text(store.lastError).font(.system(size: 12))
                            }
                        }
                    }
                    runCard
                    accountStrip
                    results
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("任务")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var runCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("一键全流程", systemImage: "checklist").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Pill(text: store.taskRunning ? "执行中" : "待命",
                         color: store.taskRunning ? Theme.warn : Theme.ok)
                }
                Text("签到 → 活跃上报 → 桌面事件 → 补签 → 礼包补偿 → 成长任务 → 连登兑换 → 抽奖 → 猫猫旅行")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button {
                    Task { @MainActor in await TaskRunner.shared.runFromUI(store: store) }
                } label: {
                    HStack {
                        Image(systemName: store.taskRunning ? "hourglass" : "play.fill")
                        Text(store.taskRunning ? "正在执行…" : "立即执行全部任务")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.gradient))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(store.taskRunning)

                HStack(spacing: 8) {
                    Button {
                        Task { @MainActor in
                            store.taskRunning = true
                            store.currentTasks = []
                            let r = await TaskRunner.shared.runNightWindow()
                            store.currentTasks = r.steps
                            store.taskRunning = false
                        }
                    } label: {
                        Label("夜猫子窗口", systemImage: "moon.stars").font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { @MainActor in
                            for account in store.activeAccounts {
                                let step = await TaskRunner.shared.checkin(account)
                                store.currentTasks.append(TaskStep(label: step.label + "-" + account.displayName,
                                                                   ok: step.ok, message: step.message))
                            }
                        }
                    } label: {
                        Label("仅签到", systemImage: "calendar.badge.checkmark").font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if store.settings.autoTask {
                    Text("自动执行：每天 \(String(format: "%02d:%02d", store.settings.taskHour, store.settings.taskMinute))" +
                         (store.settings.nightTask ? " · 夜间 23:00 夜猫子" : ""))
                        .font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.7))
                }
            }
        }
    }

    private var accountStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "账号状态")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.accounts) { account in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Circle().fill(account.disabled ? Theme.err : Theme.ok).frame(width: 6, height: 6)
                                Text(account.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            }
                            Text("\(Int(account.credits)) 积分").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.warn)
                            Text(account.lastRun.isEmpty ? "未执行" : account.lastRun)
                                .font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.7))
                        }
                        .padding(11)
                        .frame(width: 132, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.card))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "本次结果")
                Spacer()
                if !store.currentTasks.isEmpty {
                    Text("\(store.currentTasks.filter(\.ok).count)/\(store.currentTasks.count)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            if store.currentTasks.isEmpty {
                Card {
                    Text("还没有执行记录。点上面的按钮开始。")
                        .font(.system(size: 12)).foregroundStyle(Color.secondary.opacity(0.7))
                }
            } else {
                ForEach(store.currentTasks) { step in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: step.ok ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(step.ok ? Theme.ok : Theme.warn)
                            .font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Text(step.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                }
            }
        }
    }
}
