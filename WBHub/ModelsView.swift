import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""
    @State private var busy = false
    @State private var error = ""

    private var filtered: [RemoteModel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.models }
        return store.models.filter {
            $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    var body: some View {
        Screen("模型", trailing: AnyView(
            Button {
                Task { await reload() }
            } label: {
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .disabled(busy)
        )) {
            defaultCard
            searchBar
            if filtered.isEmpty {
                Panel {
                    EmptyHint(icon: store.models.isEmpty ? "cube.transparent" : "magnifyingglass",
                              title: store.models.isEmpty ? "还没有模型" : "没有匹配的模型",
                              detail: store.models.isEmpty
                                  ? "点右上角刷新，或先在「账号」页登录"
                                  : "换个关键词试试",
                              actionTitle: store.models.isEmpty ? "重新拉取" : nil) {
                        Task { await reload() }
                    }
                }
            } else {
                Panel("全部模型 · \(filtered.count)") {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, model in
                        modelRow(model)
                        if index < filtered.count - 1 { RowDivider(inset: 40) }
                    }
                }
            }
            if !error.isEmpty {
                Panel {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.err)
                        .padding(Theme.rowPadH)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { if store.models.isEmpty { await reload() } }
    }

    // MARK: - 默认模型

    private var currentModel: RemoteModel? {
        let id = store.settings.defaultModel
        return store.models.first { $0.id == id }
    }

    private var defaultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("默认模型")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                Spacer()
                if store.settings.defaultModel == "auto" {
                    Text("auto")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                        .foregroundStyle(.white)
                }
            }
            Text(store.settings.defaultModel)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)

            HStack(spacing: 6) {
                if let m = currentModel {
                    chip("ctx \(Num.compact(m.contextWindow))")
                    chip("out \(Num.compact(m.maxTokens))")
                    if m.supportsImages { chip("视觉") }
                } else {
                    chip("自动选择可用模型")
                }
                Spacer()
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Theme.gradient))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.18)))
            .foregroundStyle(.white)
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondary.opacity(0.6))
            TextField("搜索模型 id 或名称", text: $query)
                .font(.system(size: 12.5))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.soft))
    }

    // MARK: - 模型行

    private func modelRow(_ model: RemoteModel) -> some View {
        let selected = model.id == store.settings.defaultModel
        return TapRow(action: {
            store.updateSettings { $0.defaultModel = model.id }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            store.log("默认模型改为 \(model.id)", .ok)
        }) {
            HStack(spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.35))

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.id)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .monospaced))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("ctx \(Num.compact(model.contextWindow))")
                        Text("·")
                        Text("out \(Num.compact(model.maxTokens))")
                        if !model.credits.isEmpty {
                            Text("·")
                            Text(model.credits)
                        }
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                }

                Spacer(minLength: 4)

                if model.supportsImages {
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent2)
                }
            }
            .padding(.horizontal, Theme.rowPadH)
            .padding(.vertical, 9)
        }
    }

    private func reload() async {
        busy = true
        error = ""
        await ServerManager.shared.reloadModels()
        if store.models.isEmpty { error = "拉取失败，检查账号凭证或上游地址" }
        busy = false
    }
}
