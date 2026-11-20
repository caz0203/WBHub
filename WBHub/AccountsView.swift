import SwiftUI
import UIKit

struct AccountsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showLogin = false
    @State private var showImport = false
    @State private var editing: Account?
    @State private var pendingDelete: Account?
    @State private var busy = false

    var body: some View {
        Screen("账号", trailing: AnyView(
            Menu {
                Button { showLogin = true } label: { Label("扫码登录", systemImage: "qrcode") }
                Button { showImport = true } label: { Label("粘贴 AT / RT", systemImage: "square.and.arrow.down") }
                if !store.accounts.isEmpty {
                    Divider()
                    Button {
                        Task { await refreshAll() }
                    } label: { Label("刷新全部凭证", systemImage: "arrow.clockwise") }
                }
            } label: {
                Image(systemName: "plus")
            }
        )) {
            overview
            actionPanel
            if store.accounts.isEmpty {
                Panel {
                    EmptyHint(icon: "person.crop.circle.badge.plus",
                              title: "还没有账号",
                              detail: "扫码登录会走官方设备授权，登录后自动拉取昵称与积分",
                              actionTitle: "扫码登录") { showLogin = true }
                }
            } else {
                if !cnAccounts.isEmpty { group("国内版", cnAccounts) }
                if !globalAccounts.isEmpty { group("国际版", globalAccounts) }
            }
            footer
        }
        .sheet(isPresented: $showLogin) { LoginView() }
        .sheet(isPresented: $showImport) { ImportView() }
        .sheet(item: $editing) { account in
            AccountEditView(account: account)
        }
        .alert("删除账号？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let a = pendingDelete { store.remove(a) }
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete.map { "将移除「\($0.displayName)」及其凭证。" } ?? "")
        }
    }

    // MARK: - 概览

    private var overview: some View {
        HStack(spacing: 8) {
            tile("账号", "\(store.accounts.count)",
                 store.accounts.count == store.activeAccounts.count ? "全部启用" : "\(store.activeAccounts.count) 启用",
                 Theme.accent)
            tile("总积分", Num.compact(Int(totalCredits)),
                 store.accounts.isEmpty ? "暂无数据" : "跨账号合计", Theme.warn)
        }
    }

    private func tile(_ title: String, _ value: String, _ hint: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.85))
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(hint)
                .font(.system(size: 9))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.card))
    }

    private var totalCredits: Double {
        store.accounts.reduce(0) { $0 + $1.credits }
    }

    // MARK: - 添加

    private var actionPanel: some View {
        Panel("添加账号") {
            TapRow(action: { showLogin = true }) {
                InfoRow("扫码登录", subtitle: "官方设备授权，自动收取 token",
                        icon: "qrcode", showChevron: true) {
                    Pill(text: "推荐", color: Theme.ok)
                }
            }
            RowDivider(inset: 54)
            TapRow(action: { showImport = true }) {
                InfoRow("粘贴 AT / RT", subtitle: "已有凭证时直接导入，支持多行",
                        icon: "square.and.arrow.down", showChevron: true)
            }
        }
    }

    // MARK: - 分组

    private var cnAccounts: [Account] { store.accounts.filter { $0.realm == .cn } }
    private var globalAccounts: [Account] { store.accounts.filter { $0.realm == .global } }

    private func group(_ title: String, _ accounts: [Account]) -> some View {
        Panel("\(title) · \(accounts.count)") {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                accountRow(account)
                if index < accounts.count - 1 { RowDivider(inset: 56) }
            }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        TapRow(action: { editing = account }) {
            HStack(spacing: 10) {
                avatar(account)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(account.displayName)
                            .font(.system(size: 13.5, weight: .medium))
                            .lineLimit(1)
                        if account.disabled {
                            Pill(text: "停用", color: Theme.err)
                        } else if account.needsRefresh {
                            Pill(text: "待刷新", color: Theme.warn)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("\(Num.credit(account.credits)) 积分")
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(Theme.warn)
                        if !account.lastRun.isEmpty {
                            Text("· \(account.lastRun)")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.secondary.opacity(0.7))
                        }
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.35))
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, 10)
        }
        .contextMenu {
            Button {
                Task { await refresh(account) }
            } label: { Label("刷新凭证与积分", systemImage: "arrow.clockwise") }
            Button {
                Task { await checkinOnly(account) }
            } label: { Label("只跑签到", systemImage: "checkmark.circle") }
            Button {
                store.update(account) { $0.disabled.toggle() }
            } label: {
                Label(account.disabled ? "启用" : "停用",
                      systemImage: account.disabled ? "play.circle" : "pause.circle")
            }
            Divider()
            Button(role: .destructive) {
                pendingDelete = account
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func avatar(_ account: Account) -> some View {
        let name = account.displayName
        let initial = name.isEmpty ? "?" : String(name.prefix(1))
        return ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.gradient.opacity(account.disabled ? 0.35 : 1))
                .frame(width: 34, height: 34)
            Text(initial)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var footer: some View {
        VStack(spacing: 2) {
            Text("凭证仅保存在本机")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.secondary.opacity(0.6))
            Text("作者 小帅 · QQ \(AppInfo.authorQQ)")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .textSelection(.enabled)
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

    private func refresh(_ account: Account) async {
        _ = await Upstream.shared.ensureFresh(account)
        if let c = await Upstream.shared.credits(account) {
            store.update(account) { $0.credits = c.total }
        }
        store.log("已刷新：\(account.displayName)", .ok)
    }

    private func checkinOnly(_ account: Account) async {
        let r = await TaskRunner.shared.runOne(account, night: false, onlyCheckin: true)
        store.currentTasks.append(contentsOf: r.steps)
        store.log(r.steps.first?.message ?? "签到完成", .info)
    }
}

// MARK: - 账号编辑

struct AccountEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let account: Account

    @State private var nickname = ""
    @State private var realm: Realm = .cn
    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var disabled = false
    @State private var reveal = false
    @State private var busy = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    Panel("资料") {
                        fieldRow("昵称", text: $nickname, placeholder: "显示名称")
                        RowDivider(inset: 54)
                        HStack {
                            Text("版本").font(.system(size: 13.5))
                            Spacer()
                            SegmentedBar(items: [(Realm.cn, "国内版"), (Realm.global, "国际版")],
                                         selection: $realm)
                                .frame(width: 150)
                        }
                        .padding(.horizontal, Theme.rowPadH)
                        .padding(.vertical, 8)
                        RowDivider(inset: 54)
                        HStack {
                            Text("启用").font(.system(size: 13.5))
                            Spacer()
                            Toggle("", isOn: $disabled.map { !$0 }).labelsHidden().tint(Theme.accent)
                        }
                        .padding(.horizontal, Theme.rowPadH)
                        .padding(.vertical, 6)
                    }

                    Panel("凭证", note: "AT 短期有效，RT 用于续期。留空 RT 时无法自动刷新。") {
                        HStack {
                            Text("显示明文").font(.system(size: 13.5))
                            Spacer()
                            Toggle("", isOn: $reveal).labelsHidden().tint(Theme.accent)
                        }
                        .padding(.horizontal, Theme.rowPadH)
                        .padding(.vertical, 6)
                        RowDivider(inset: 54)
                        secretRow("AT", text: $accessToken)
                        RowDivider(inset: 54)
                        secretRow("RT", text: $refreshToken)
                        if !errorMessage.isEmpty {
                            RowDivider(inset: 54)
                            Text(errorMessage)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.err)
                                .padding(.horizontal, Theme.rowPadH)
                                .padding(.vertical, 9)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Panel("操作") {
                        TapRow(action: { Task { await refresh() } }) {
                            InfoRow("刷新凭证与积分", icon: "arrow.clockwise") {
                                if busy { ProgressView().controlSize(.small) }
                            }
                        }
                        RowDivider(inset: 54)
                        TapRow(action: { Task { await checkin() } }) {
                            InfoRow("只跑签到", icon: "checkmark.circle") { EmptyView() }
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.bottom, 24)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("编辑账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }.font(.body.bold())
                }
            }
            .onAppear {
                nickname = account.displayName
                realm = account.realm
                accessToken = account.accessToken
                refreshToken = account.refreshToken
                disabled = account.disabled
            }
        }
    }

    private func fieldRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13.5))
                .frame(width: 40, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.system(size: 13))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Theme.rowPadH)
        .padding(.vertical, 10)
    }

    private func secretRow(_ label: String, text: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 13.5))
                .frame(width: 40, alignment: .leading)
                .padding(.top, 6)
            Group {
                if reveal {
                    TextEditor(text: text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 58)
                } else {
                    SecureField("", text: text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
        }
        .padding(.horizontal, Theme.rowPadH)
        .padding(.vertical, 9)
    }

    private func save() {
        var updated = account
        updated.nickname = nickname
        updated.realm = realm
        updated.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.refreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.disabled = disabled
        store.update(account) { a in
            a.nickname = updated.nickname
            a.realm = updated.realm
            a.accessToken = updated.accessToken
            a.refreshToken = updated.refreshToken
            a.disabled = updated.disabled
        }
        store.log("已保存：\(updated.displayName)", .ok)
        dismiss()
    }

    private func refresh() async {
        busy = true
        errorMessage = ""
        let fresh = await Upstream.shared.ensureFresh(account)
        if let c = await Upstream.shared.credits(fresh) {
            store.update(account) { $0.credits = c.total }
            store.log("\(account.displayName)：\(Num.credit(c.total)) 积分", .ok)
        } else {
            errorMessage = "获取积分失败，凭证可能已失效"
        }
        busy = false
    }

    private func checkin() async {
        busy = true
        let r = await TaskRunner.shared.runOne(account, night: false, onlyCheckin: true)
        store.currentTasks.append(contentsOf: r.steps)
        store.log(r.steps.first?.message ?? "签到完成", .info)
        busy = false
    }
}

// MARK: - 导入

struct ImportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var realm: Realm = .cn
    @State private var result = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    Panel("导入格式", note: "每行一个账号。支持 手机号:AT:RT、AT:RT、仅 RT 三种写法。") {
                        HStack {
                            Text("版本").font(.system(size: 13.5))
                            Spacer()
                            SegmentedBar(items: [(Realm.cn, "国内版"), (Realm.global, "国际版")],
                                         selection: $realm)
                                .frame(width: 150)
                        }
                        .padding(.horizontal, Theme.rowPadH)
                        .padding(.vertical, 8)
                        RowDivider(inset: 54)
                        TextEditor(text: $text)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(minHeight: 150)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                    }

                    if !result.isEmpty {
                        Panel("结果") {
                            Text(result)
                                .font(.system(size: 11))
                                .padding(Theme.rowPadH)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            if let s = UIPasteboard.general.string { text = s }
                        } label: {
                            Label("粘贴", systemImage: "doc.on.clipboard")
                                .font(.system(size: 12.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.soft))
                        }
                        .buttonStyle(.plain)

                        Button {
                            text = ""
                        } label: {
                            Label("清空", systemImage: "trash")
                                .font(.system(size: 12.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.soft))
                                .foregroundStyle(Theme.err)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.bottom, 24)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("粘贴导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("导入") { runImport() }.font(.body.bold())
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func runImport() {
        var added = 0, skipped = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            var phone = "", at = "", rt = ""
            switch parts.count {
            case 1: rt = parts[0]
            case 2: at = parts[0]; rt = parts[1]
            default: phone = parts[0]; at = parts[1]; rt = parts[2]
            }
            if at.isEmpty && rt.isEmpty { skipped += 1; continue }
            if store.accounts.contains(where: { !$0.uid.isEmpty && !at.isEmpty && $0.accessToken == at }) {
                skipped += 1; continue
            }
            var account = Account()
            account.realm = realm
            account.phone = phone
            account.nickname = phone.isEmpty ? "账号\(store.accounts.count + 1)" : phone
            account.accessToken = at
            account.refreshToken = rt
            account.uid = account.uid.isEmpty ? Hashing.uuidFrom(at.isEmpty ? rt : at) : account.uid
            store.upsert(account)
            added += 1
        }
        store.log("导入完成：新增 \(added)，跳过 \(skipped)", added > 0 ? .ok : .warn)
        result = "新增 \(added) 个，跳过 \(skipped) 个"
        if added > 0 {
            Task { await store.refreshCreditsAsync() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                dismiss()
            }
        }
    }
}

// MARK: - helper

private extension Binding where Value == Bool {
    /// 用「停用」布尔反向绑定到「启用」开关
    func map(_ transform: @escaping (Bool) -> Bool) -> Binding<Bool> {
        Binding<Bool>(get: { transform(wrappedValue) },
                      set: { wrappedValue = transform($0) })
    }
}
