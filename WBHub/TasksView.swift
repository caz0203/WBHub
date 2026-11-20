import SwiftUI

struct TasksView: View {
    @EnvironmentObject var store: AppStore
    @State private var showOnlyFailed = false

    private var visibleSteps: [TaskStep] {
        showOnlyFailed ? store.currentTasks.filter { !$0.ok } : store.currentTasks
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    if !store.lastError.isEmpty {
                        Panel {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.warn)
                                Text(store.lastError).font(.system(size: 12))
                                Spacer()
                            }
                            .padding(14)
                        }
                    }
                    runPanel
                    accountPanel
                    resultPanel
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 26)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !store.currentTasks.isEmpty {
                        Button {
                            showOnlyFailed.toggle()
                        } label: {
                            Image(systemName: showOnlyFailed ? "line.3.horizontal.decrease.circle.fill"
                                                             : "line.3.horizontal.decrease.circle")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 运行

    private var runPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("一键全流程")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                    Text(store.taskRunning ? "正在执行…" : "待命")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                if store.taskRunning {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "checklist")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            }

            Text("签到 → 活跃上报 → 桌面事件 → 补签 → 礼包补偿 → 成长任务 → 连登兑换 → 抽奖 → 猫猫旅行 → 活动页")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await TaskRunner.shared.runFromUI(store: store) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.taskRunning ? "hourglass" : "play.fill")
                    Text(store.taskRunning ? "执行中" : "立即执行全部任务")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(store.taskRunning ? 0.15 : 0.22)))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(store.taskRunning)

            if store.settings.autoTask {
                Text("自动执行：每天 \(String(format: "%02d:%02d", store.settings.taskHour, store.settings.taskMinute))"
                     + (store.settings.nightTask ? " · 夜间 23:05 夜猫子" : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.gradient))
    }

    // MARK: - 账号

    private var accountPanel: some View {
        Panel("账号状态") {
            if store.accounts.isEmpty {
                EmptyHint(icon: "person.crop.circle.badge.plus", title: "没有账号",
                          detail: "去「账号」页登录后再跑任务")
            } else {
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(account.disabled ? Theme.err : Theme.ok)
                            .frame(width: 6, height: 6)
                        Text(account.displayName).font(.system(size: 12)).lineLimit(1)
                        if account.realm == .global {
                            Pill(text: "国际", color: Theme.accent2)
                        }
                        Spacer()
                        Text("\(fmt(account.credits)) 分")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.warn)
                        Text(account.lastRun.isEmpty ? "未跑" : account.lastRun)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary.opacity(0.75))
                            .frame(width: 72, alignment: .trailing)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    if index < store.accounts.count - 1 { RowDivider(inset: 30) }
                }
            }
        }
    }

    // MARK: - 结果

    private var resultPanel: some View {
        Panel("本次结果", note: store.currentTasks.isEmpty ? nil
              : "成功 \(store.currentTasks.filter(\.ok).count) / \(store.currentTasks.count)") {
            if store.currentTasks.isEmpty {
                EmptyHint(icon: "list.bullet.clipboard", title: "还没有执行记录",
                          detail: "点上面的按钮开始")
            } else if visibleSteps.isEmpty {
                EmptyHint(icon: "checkmark.circle", title: "全部成功", detail: "没有失败项")
            } else {
                ForEach(Array(visibleSteps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: step.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(step.ok ? Theme.ok : Theme.warn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.label)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.secondary.opacity(0.75))
                            Text(step.message)
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    if index < visibleSteps.count - 1 { RowDivider(inset: 14) }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 3) {
            Text("每一步幂等，重复执行只补缺口")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.7))
            Text("作者 小帅 · QQ \(AppInfo.authorQQ)")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.0f", value)
    }
}
