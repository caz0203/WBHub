import SwiftUI

struct AccountsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showLogin = false
    @State private var editing: Account?
    @State private var importText = ""
    @State private var showImport = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    if store.accounts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没有账号").font(.system(size: 13, weight: .semibold))
                            Text("用扫码登录添加，或粘贴 AT/RT 导入。").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(store.accounts) { account in
                        accountRow(account)
                    }
                    .onDelete { indexSet in
                        for i in indexSet { store.remove(store.accounts[i]) }
                    }
                } header: {
                    Text("账号池（\(store.accounts.count)）")
                }

                Section {
                    Button {
                        showLogin = true
                    } label: {
                        Label("登录新账号（扫码）", systemImage: "qrcode")
                    }
                    Button {
                        showImport = true
                    } label: {
                        Label("粘贴 AT / RT 导入", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        Task { @MainActor in
                            await Upstream.shared.refreshAll()
                            await store.refreshCreditsAsync()
                        }
                    } label: {
                        Label("刷新全部凭证与积分", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("添加")
                }
            }
            .navigationTitle("账号")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showLogin) { LoginView() }
            .sheet(item: $editing) { account in
                AccountEditView(account: account)
            }
            .sheet(isPresented: $showImport) { ImportView() }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        Button {
            editing = account
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(account.realm == .cn ? Theme.accent.opacity(0.15) : Theme.accent2.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Text(String(account.displayName.prefix(1)))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(account.realm == .cn ? Theme.accent : Theme.accent2)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Pill(text: account.realm.label,
                             color: account.realm == .cn ? Theme.accent : Theme.accent2)
                        if account.disabled { Pill(text: "已停用", color: Theme.err) }
                    }
                    Text("\(Int(account.credits)) 积分 · \(account.lastRun.isEmpty ? "未跑任务" : "上次 " + account.lastRun)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if account.tokenExpired {
                        Text("凭证可能过期，点开刷新").font(.system(size: 10)).foregroundStyle(Theme.warn)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Color.secondary.opacity(0.7))
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}

struct AccountEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var account: Account
    @State private var busy = false

    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("昵称", text: $account.nickname)
                    TextField("UID", text: $account.uid).textInputAutocapitalization(.never)
                    Picker("版本", selection: $account.realm) {
                        ForEach(Realm.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("domain", text: $account.domain).textInputAutocapitalization(.never)
                    TextField("企业 ID（可选）", text: $account.enterpriseID).textInputAutocapitalization(.never)
                    Toggle("停用（不参与调度）", isOn: $account.disabled)
                }
                Section("凭证") {
                    TextEditor(text: $account.accessToken).frame(minHeight: 70).font(.system(size: 11, design: .monospaced))
                    TextEditor(text: $account.refreshToken).frame(minHeight: 70).font(.system(size: 11, design: .monospaced))
                    TextField("设备 Token（可选）", text: $account.deviceToken)
                }
                Section {
                    Button {
                        Task { @MainActor in
                            busy = true
                            if let updated = try? await Upstream.shared.refresh(account) {
                                account = updated
                                store.upsert(updated)
                                if let c = await Upstream.shared.credits(updated) {
                                    account.credits = c.total
                                    store.upsert(account)
                                }
                            }
                            busy = false
                        }
                    } label: {
                        HStack { Label("刷新凭证与积分", systemImage: "arrow.clockwise"); if busy { Spacer(); ProgressView() } }
                    }
                    Button {
                        Task { @MainActor in
                            let step = await TaskRunner.shared.checkin(account)
                            store.currentTasks.append(step)
                        }
                    } label: {
                        Label("只跑签到", systemImage: "calendar.badge.checkmark")
                    }
                }
            }
            .navigationTitle(account.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("删除") { store.remove(account); dismiss() }.foregroundStyle(Theme.err)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { store.upsert(account); dismiss() }.font(.body.bold())
                }
            }
        }
    }
}

struct ImportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var realm: Realm = .cn

    var body: some View {
        NavigationView {
            Form {
                Section("格式") {
                    Text("每行一个账号：手机号:AT:RT，或只粘贴 AT:RT / RT。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("版本", selection: $realm) {
                        ForEach(Realm.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("内容") {
                    TextEditor(text: $text).frame(minHeight: 180).font(.system(size: 11, design: .monospaced))
                }
                Section {
                    Button {
                        importAccounts()
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("导入账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } } }
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
