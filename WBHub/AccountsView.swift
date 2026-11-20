import SwiftUI
import UIKit

/// 账号页：账号池总览 + 扫码登录（二维码/链接） + 手动导入 + 单账号编辑。
struct AccountsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showLogin = false
    @State private var editing: Account?
    @State private var showImport = false
    @State private var busy = false

    private var cn: [Account] { store.accounts.filter { $0.realm == .cn } }
    private var global: [Account] { store.accounts.filter { $0.realm == .global } }
    private var totalCredits: Double { store.accounts.reduce(0) { $0 + $1.credits } }
    private var healthyCount: Int { store.accounts.filter { !$0.disabled && !$0.tokenExpired }.count }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    overview
                    actionPanel
                    if store.accounts.isEmpty {
                        Panel { EmptyHint(icon: "person.crop.circle.badge.plus",
                                          title: "还没有账号",
                                          detail: "扫码登录或粘贴 AT / RT 导入，登录后即可反代和跑任务") }
                    } else {
                        if !cn.isEmpty { group(title: "国内版", accounts: cn) }
                        if !global.isEmpty { group(title: "国际版", accounts: global) }
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        if busy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(busy || store.accounts.isEmpty)
                }
            }
            .sheet(isPresented: $showLogin) { LoginView() }
            .sheet(isPresented: $showImport) { ImportView() }
            .sheet(item: $editing) { account in AccountEditView(account: account) }
        }
    }

    // MARK: - 概览

    private var overview: some View {
        HStack(spacing: 10) {
            StatTile(title: "账号", value: "\(store.accounts.count)",
                     hint: healthyCount == store.accounts.count ? "全部正常"
                         : "\(healthyCount) 个正常",
                     tint: Theme.accent)
            StatTile(title: "总积分", value: fmt(totalCredits),
                     hint: "国内 \(cn.count) · 国际 \(global.count)",
                     tint: Theme.warn)
        }
    }

    // MARK: - 操作区

    private var actionPanel: some View {
        Panel("添加账号", note: "扫码登录走官方设备授权，不需要桌面端；登录后自动拉取昵称与积分。") {
            Button { showLogin = true } label: {
                InfoRow("扫码登录", subtitle: "打开浏览器授权，App 自动收 token", icon: "qrcode", showChevron: true) {
                    Pill(text: "推荐", color: Theme.ok)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowDivider(inset: 55)
            Button { showImport = true } label: {
                InfoRow("粘贴 AT / RT", subtitle: "已有凭证时直接导入，支持多行", icon: "square.and.arrow.down",
                    showChevron: true) { EmptyView() }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 账号分组

    private func group(title: String, accounts: [Account]) -> some View {
        Panel("\(title) · \(accounts.count)") {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                accountRow(account)
                if index < accounts.count - 1 { RowDivider(inset: 55) }
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        Button { editing = account } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(account.disabled ? Theme.err.opacity(0.13) : Theme.accent.opacity(0.13))
                        .frame(width: 34, height: 34)
                    Text(String(account.displayName.prefix(1)))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(account.disabled ? Theme.err : Theme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(account.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if account.disabled { Pill(text: "停用", color: Theme.err) }
                        if account.tokenExpired { Pill(text: "待刷新", color: Theme.warn) }
                    }
                    HStack(spacing: 8) {
                        Text("\(fmt(account.credits)) 积分")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.warn)
                        Text(account.lastRun.isEmpty ? "未跑任务" : "上次 \(account.lastRun)")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary.opacity(0.8))
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await runCheckin(account) }
            } label: { Label("只跑签到", systemImage: "calendar.badge.checkmark") }
            Button {
                Task { await refreshOne(account) }
            } label: { Label("刷新凭证", systemImage: "key") }
            Button(role: .destructive) {
                store.remove(account)
            } label: { Label("删除账号", systemImage: "trash") }
        }
    }

    private var footer: some View {
        VStack(spacing: 3) {
            Text("凭证仅保存在本机 App 沙盒")
                .font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.7))
            Text("作者 小帅 · QQ \(AppInfo.authorQQ)")
                .font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    // MARK: - 动作

    private func refreshAll() async {
        busy = true
        await Upstream.shared.refreshAll()
        await store.refreshCreditsAsync()
        busy = false
    }

    private func refreshOne(_ account: Account) async {
        if let updated = try? await Upstream.shared.refresh(account) {
            store.upsert(updated)
            if let c = await Upstream.shared.credits(updated) {
                var copy = updated
                copy.credits = c.total
                store.upsert(copy)
            }
            store.log("\(account.displayName) 凭证已刷新", .ok)
        } else {
            store.log("\(account.displayName) 刷新失败", .err)
        }
    }

    private func runCheckin(_ account: Account) async {
        let step = await TaskRunner.shared.checkin(account)
        store.currentTasks.append(step)
        store.log(step.message, step.ok ? .ok : .warn)
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - 账号编辑

struct AccountEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var account: Account
    @State private var busy = false
    @State private var showSecrets = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    Panel("基本信息") {
                        labeledField("昵称", $account.nickname)
                        RowDivider()
                        labeledField("UID", $account.uid)
                        RowDivider()
                        HStack {
                            Text("版本").font(.system(size: 13))
                            Spacer()
                            SegmentedBar(items: [(Realm.cn, "国内版"), (Realm.global, "国际版")],
                                         selection: $account.realm)
                                .frame(width: 150)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        RowDivider()
                        labeledField("domain", $account.domain)
                        RowDivider()
                        labeledField("企业 ID（可选）", $account.enterpriseID)
                        RowDivider()
                        HStack {
                            Text("停用").font(.system(size: 13))
                            Spacer()
                            Toggle("", isOn: $account.disabled).labelsHidden().tint(Theme.err)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    Panel("凭证", note: "AT 短期有效，RT 用于续期。留空 RT 时无法自动刷新。") {
                        HStack {
                            Text("显示明文").font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("", isOn: $showSecrets).labelsHidden().tint(Theme.accent)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        RowDivider()
                        secretEditor("Access Token", text: $account.accessToken)
                        RowDivider()
                        secretEditor("Refresh Token", text: $account.refreshToken)
                        RowDivider()
                        labeledField("设备 Token（可选）", $account.deviceToken)
                    }
                    Panel {
                        Button {
                            Task { await refresh() }
                        } label: {
                            HStack {
                                Label("刷新凭证与积分", systemImage: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .medium))
                                if busy { Spacer(); ProgressView().controlSize(.small) }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        RowDivider()
                        Button {
                            Task {
                                let step = await TaskRunner.shared.checkin(account)
                                store.currentTasks.append(step)
                                store.log(step.message, step.ok ? .ok : .warn)
                            }
                        } label: {
                            Label("只跑签到", systemImage: "calendar.badge.checkmark")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14).padding(.vertical, 13)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        RowDivider()
                        Button {
                            store.remove(account)
                            dismiss()
                        } label: {
                            Label("删除账号", systemImage: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.err)
                                .padding(.horizontal, 14).padding(.vertical, 13)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle(account.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { store.upsert(account); dismiss() }
                        .font(.body.bold())
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.13)).frame(width: 46, height: 46)
                Text(String(account.displayName.prefix(1)))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName).font(.system(size: 15, weight: .semibold))
                Text("\(account.realm.label) · \(fmt(account.credits)) 积分")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if account.tokenExpired {
                    Text("凭证可能已过期，点下方刷新").font(.system(size: 10)).foregroundStyle(Theme.warn)
                }
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private func labeledField(_ label: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 13)).frame(width: 92, alignment: .leading)
            TextField(label, text: text)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func secretEditor(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextEditor(text: showSecrets ? text : .constant(masked(text.wrappedValue)))
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 58)
                .disabled(!showSecrets)
                .opacity(showSecrets ? 1 : 0.7)
            if !text.wrappedValue.isEmpty {
                Text("\(text.wrappedValue.count) 字符")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func masked(_ text: String) -> String {
        guard text.count > 12 else { return String(repeating: "•", count: text.count) }
        return String(text.prefix(6)) + String(repeating: "•", count: 18) + String(text.suffix(4))
    }

    private func refresh() async {
        busy = true
        if let updated = try? await Upstream.shared.refresh(account) {
            account = updated
            store.upsert(updated)
            if let c = await Upstream.shared.credits(updated) {
                account.credits = c.total
                store.upsert(account)
            }
            store.log("\(account.displayName) 已刷新", .ok)
        } else {
            store.log("\(account.displayName) 刷新失败，可能需要重新登录", .err)
        }
        busy = false
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - 导入

struct ImportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var realm: Realm = .cn

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    Panel("导入格式", note: "每行一个账号。支持 手机号:AT:RT、AT:RT、仅 RT 三种写法。") {
                        HStack {
                            Text("版本").font(.system(size: 13))
                            Spacer()
                            SegmentedBar(items: [(Realm.cn, "国内版"), (Realm.global, "国际版")],
                                         selection: $realm)
                                .frame(width: 150)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    Panel("粘贴内容") {
                        TextEditor(text: $text)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 200)
                            .padding(8)
                    }
                    Panel {
                        Button {
                            importAccounts()
                        } label: {
                            Text("导入")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("导入账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
    }

    @MainActor private func importAccounts() {
        var count = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.components(separatedBy: ":")
            var access = ""
            var refresh = ""
            if parts.count >= 3 {
                access = parts[parts.count - 2]
                refresh = parts[parts.count - 1]
            } else if parts.count == 2 {
                access = parts[0]
                refresh = parts[1]
            } else {
                refresh = line
            }
            var account = Account()
            account.realm = realm
            account.accessToken = access
            account.refreshToken = refresh
            account.uid = Upstream.uidFromJWT(access.isEmpty ? refresh : access)
            account.domain = realm == .global ? "www.workbuddy.ai" : "copilot.tencent.com"
            account.nickname = "导入 \(account.uid.prefix(6))"
            store.upsert(account)
            count += 1
        }
        store.log("已导入 \(count) 个账号", .ok)
        dismiss()
    }
}
