import SwiftUI
import UIKit

/// 扫码登录：请求设备授权 → 展示二维码 + 可复制链接 + 一键打开 → 轮询拿 token。
struct LoginView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var realm: Realm = .cn
    @State private var session: Upstream.LoginSession?
    @State private var status = "选择版本后获取授权链接"
    @State private var polling = false
    @State private var error = ""
    @State private var pollTask: Task<Void, Never>?
    @State private var elapsed = 0

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    realmPicker
                    if let session = session {
                        qrCard(session)
                        linkCard(session)
                    } else {
                        startCard
                    }
                    statusCard
                    tips
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        polling = false
                        pollTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onDisappear { pollTask?.cancel() }
        }
    }

    // MARK: - 版本

    private var realmPicker: some View {
        Panel("登录版本", note: "国内版与国际版账号体系独立，凭证不能混用。") {
            HStack {
                SegmentedBar(items: [(Realm.cn, "国内版"), (Realm.global, "国际版")], selection: $realm)
            }
            .padding(14)
            .onChange(of: realm) { _ in
                pollTask?.cancel()
                polling = false
                session = nil
                error = ""
                status = "版本已切换，请重新获取授权"
            }
        }
    }

    // MARK: - 起始

    private var startCard: some View {
        Panel {
            Button {
                Task { await begin() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 15, weight: .semibold))
                    Text("获取授权二维码")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 二维码

    private func qrCard(_ session: Upstream.LoginSession) -> some View {
        VStack(spacing: 14) {
            HStack {
                Label("扫码授权", systemImage: "qrcode")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Pill(text: polling ? "等待授权" : "已停止",
                     color: polling ? Theme.warn : Color.secondary)
            }
            QRCodeView(text: session.authURL, size: 220)
                .frame(maxWidth: .infinity)
            Text("用手机相机或 WorkBuddy App 扫码；也可以复制链接到浏览器打开")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if polling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("已等待 \(elapsed)s，正在轮询授权结果…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }

    // MARK: - 链接

    private func linkCard(_ session: Upstream.LoginSession) -> some View {
        Panel("授权链接") {
            CopyField(label: "授权地址", value: session.authURL, mono: true)
            RowDivider()
            Button {
                if let url = URL(string: session.authURL) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("在浏览器打开", systemImage: "arrow.up.right.square")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            RowDivider()
            Button {
                Task { await reload() }
            } label: {
                Label(polling ? "重新获取（会作废旧链接）" : "刷新链接",
                      systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        Panel("状态") {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: iconForStatus)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colorForStatus)
                Text(status)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            if !error.isEmpty {
                RowDivider()
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.err)
                    .padding(14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var iconForStatus: String {
        if !error.isEmpty { return "exclamationmark.triangle.fill" }
        if status.contains("成功") { return "checkmark.circle.fill" }
        if polling { return "hourglass" }
        return "info.circle"
    }

    private var colorForStatus: Color {
        if !error.isEmpty { return Theme.err }
        if status.contains("成功") { return Theme.ok }
        if polling { return Theme.warn }
        return Theme.accent
    }

    private var tips: some View {
        Panel("说明") {
            VStack(alignment: .leading, spacing: 7) {
                tipRow("1", "点击获取二维码，App 会向官方请求设备授权")
                tipRow("2", "扫码或在浏览器完成登录（任一设备都行）")
                tipRow("3", "授权成功后 App 自动收取 token，无需回到本页")
            }
            .padding(14)
        }
    }

    private func tipRow(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.accent.opacity(0.8)))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 逻辑

    @MainActor private func begin() async {
        error = ""
        status = "正在向 \(realm.label) 请求授权…"
        do {
            let s = try await Upstream.shared.startLogin(realm: realm)
            session = s
            status = "已获取授权链接，等待你完成登录"
            polling = true
            elapsed = 0
            pollTask?.cancel()
            pollTask = Task { @MainActor in await poll(s) }
        } catch {
            let e = error as? Wire.UpstreamError
            self.error = e?.message ?? error.localizedDescription
            status = "获取授权链接失败"
        }
    }

    @MainActor private func reload() async {
        pollTask?.cancel()
        polling = false
        session = nil
        await begin()
    }

    @MainActor private func poll(_ session: Upstream.LoginSession) async {
        for tick in 0..<150 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled || !polling { return }
            elapsed = (tick + 1) * 2
            switch await Upstream.shared.pollLogin(session) {
            case .pending:
                continue
            case .failed(let message):
                status = "登录失败：\(message)"
                error = message
                polling = false
                return
            case .done(var account):
                if let c = await Upstream.shared.credits(account) { account.credits = c.total }
                store.upsert(account)
                store.log("登录成功：\(account.displayName)", .ok)
                status = "登录成功：\(account.displayName)"
                polling = false
                Task { @MainActor in await ServerManager.shared.reloadModels() }
                try? await Task.sleep(nanoseconds: 900_000_000)
                dismiss()
                return
            }
        }
        polling = false
        status = "等待超时，请重新获取链接"
    }
}
