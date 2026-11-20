import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var realm: Realm = .cn
    @State private var session: Upstream.LoginSession?
    @State private var status = "选择版本后开始获取授权链接"
    @State private var polling = false
    @State private var pollTask: Task<Void, Never>?
    @State private var error: String = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("登录方式", systemImage: "qrcode.viewfinder").font(.system(size: 13, weight: .semibold))
                            Picker("版本", selection: $realm) {
                                ForEach(Realm.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: realm) { _ in session = nil; status = "版本已切换，重新获取链接" }
                            Text("在浏览器里完成 WorkBuddy 登录，App 会自动轮询拿 token。无需桌面端。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Button {
                                Task { @MainActor in await begin() }
                            } label: {
                                Label(session == nil ? "获取授权链接" : "重新获取",
                                      systemImage: "link.badge.plus")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                        }
                    }

                    if let session = session {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label("授权链接", systemImage: "safari").font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Pill(text: polling ? "等待授权" : "未开始",
                                         color: polling ? Theme.warn : Color.secondary)
                                }
                                Text(session.authURL)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Button {
                                    if let url = URL(string: session.authURL) {
                                        UIApplication.shared.open(url)
                                    }
                                } label: {
                                    Label("在浏览器打开", systemImage: "arrow.up.right.square")
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                                }
                                .buttonStyle(.bordered)
                                if polling { ProgressView().controlSize(.small) }
                            }
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("状态").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            Text(status).font(.system(size: 12))
                            if !error.isEmpty {
                                Text(error).font(.system(size: 11)).foregroundStyle(Theme.err)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { polling = false; pollTask?.cancel(); dismiss() } } }
            .onDisappear { pollTask?.cancel() }
        }
    }

    @MainActor private func begin() async {
        error = ""
        status = "正在向 \(realm.label) 请求授权…"
        do {
            let s = try await Upstream.shared.startLogin(realm: realm)
            session = s
            status = "已获取链接，请在浏览器完成登录"
            if let url = URL(string: s.authURL) { await UIApplication.shared.open(url) }
            polling = true
            pollTask?.cancel()
            pollTask = Task { @MainActor in await poll(s) }
        } catch {
            let e = error as? Wire.UpstreamError
            self.error = e?.message ?? error.localizedDescription
            status = "获取链接失败"
        }
    }

    @MainActor private func poll(_ session: Upstream.LoginSession) async {
        for _ in 0..<150 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled || !polling { return }
            switch await Upstream.shared.pollLogin(session) {
            case .pending:
                continue
            case .failed(let message):
                status = "登录失败：\(message)"
                polling = false
                return
            case .done(var account):
                if let c = await Upstream.shared.credits(account) { account.credits = c.total }
                store.upsert(account)
                store.log("登录成功：\(account.displayName)", .ok)
                status = "登录成功：\(account.displayName)"
                polling = false
                Task { @MainActor in await ServerManager.shared.reloadModels() }
                try? await Task.sleep(nanoseconds: 700_000_000)
                dismiss()
                return
            }
        }
        polling = false
        status = "等待超时，请重新获取链接"
    }
}
