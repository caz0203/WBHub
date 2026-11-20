import SwiftUI

/// 模型页：拉取账号可用模型、显示上下文与倍率、设为默认、搜索过滤。
struct ModelsView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var loading = false
    @State private var showAll = false

    private var filtered: [RemoteModel] {
        let base = store.models
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        let q = query.lowercased()
        return base.filter {
            $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
        }
    }

    private var defaultModel: RemoteModel? {
        store.models.first { $0.id == store.settings.defaultModel }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    defaultCard
                    searchBar
                    if loading && store.models.isEmpty {
                        Panel { EmptyHint(icon: "hourglass", title: "正在拉取模型", detail: "首次拉取需要几秒") }
                    } else if filtered.isEmpty {
                        Panel {
                            EmptyHint(icon: "square.stack.3d.up.slash",
                                       title: store.models.isEmpty ? "还没有模型" : "没有匹配的模型",
                                       detail: store.models.isEmpty
                                           ? "先在「账号」登录，然后点右上角刷新拉取模型目录"
                                           : "换个关键词试试")
                        }
                    } else {
                        Panel("可用模型 · \(filtered.count)") {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, model in
                                modelRow(model)
                                if index < filtered.count - 1 { RowDivider(inset: 40) }
                            }
                        }
                    }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await reload() }
                    } label: {
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(loading)
                }
            }
            .onAppear {
                if store.models.isEmpty { Task { await reload() } }
            }
        }
    }

    // MARK: - 默认模型

    private var defaultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前默认").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                    Text(defaultModel?.id ?? (store.settings.defaultModel.isEmpty ? "未设置" : store.settings.defaultModel))
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer()
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            if let model = defaultModel {
                HStack(spacing: 6) {
                    chip("\(compact(model.contextWindow)) 上下文", .white)
                    chip("\(compact(model.maxTokens)) 输出", .white)
                    if model.supportsImages { chip("支持图片", .white) }
                    if !model.credits.isEmpty { chip(model.credits, .white) }
                }
            }
            Text("客户端请求 model 为 auto 或留空时使用")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.65))
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.gradient))
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color.opacity(0.95))
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary.opacity(0.7))
            TextField("搜索模型", text: $query)
                .font(.system(size: 13))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card))
    }

    // MARK: - 模型行

    private func modelRow(_ model: RemoteModel) -> some View {
        let isDefault = model.id == store.settings.defaultModel
        return Button {
            store.updateSettings { $0.defaultModel = model.id }
            store.log("默认模型切换为 \(model.id)", .ok)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isDefault ? Theme.accent : Theme.soft)
                        .frame(width: 30, height: 30)
                    Image(systemName: isDefault ? "checkmark" : "circle")
                        .font(.system(size: 13, weight: isDefault ? .bold : .regular))
                        .foregroundStyle(isDefault ? Color.white : Color.secondary.opacity(0.6))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(model.id)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                        if model.supportsImages {
                            Image(systemName: "photo")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.accent2)
                        }
                    }
                    HStack(spacing: 6) {
                        meta("\(compact(model.contextWindow)) ctx")
                        meta("\(compact(model.maxTokens)) out")
                        if !model.credits.isEmpty { meta(model.credits) }
                    }
                }
                Spacer(minLength: 4)
                if isDefault {
                    Pill(text: "默认", color: Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func meta(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.secondary.opacity(0.8))
    }

    private var footer: some View {
        VStack(spacing: 3) {
            Text("模型目录来自 WorkBuddy 账号，\(store.models.count) 个可用")
                .font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.7))
            Text("作者 小帅 · QQ \(AppInfo.authorQQ)")
                .font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    // MARK: - 动作

    private func reload() async {
        guard !loading else { return }
        loading = true
        await ServerManager.shared.reloadModels()
        loading = false
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1000 { return String(format: "%.0fK", Double(value) / 1000) }
        return "\(value)"
    }
}
