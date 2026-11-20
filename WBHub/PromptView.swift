import SwiftUI
import UIKit

struct PromptView: View {
    @EnvironmentObject var store: AppStore
    @State private var draft: String = ""
    @State private var dirty = false
    @State private var saved = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    modeCard
                    editorCard
                    presetCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("系统提示词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }.font(.body.bold()).disabled(!dirty)
                }
            }
            .onAppear { if draft.isEmpty { draft = store.settings.promptText } }
        }
    }

    private var modeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("出站改写", systemImage: "arrow.triangle.branch").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Pill(text: store.settings.promptMode.label,
                         color: store.settings.promptMode == .off ? Color.secondary : Theme.accent)
                }
                Picker("模式", selection: Binding(
                    get: { store.settings.promptMode },
                    set: { newValue in store.updateSettings { $0.promptMode = newValue } })) {
                    ForEach(PromptMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(isOn: Binding(
                    get: { store.settings.disguise },
                    set: { value in store.updateSettings { $0.disguise = value } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("规避上游客户端标记").font(.system(size: 12, weight: .medium))
                        Text("只改写被拦的自报家门前缀，其余内容原样透传").font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.7))
                    }
                }
                .tint(Theme.accent)
            }
        }
    }

    private var editorCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("提示词内容", systemImage: "text.quote").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(draft.count) 字符").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.secondary.opacity(0.7))
                }
                TextEditor(text: $draft)
                    .font(.system(size: 12, design: .monospaced))
                    .background(Color.clear)
                    .frame(minHeight: 260)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.page))
                    .onChange(of: draft) { _ in dirty = true }
                HStack(spacing: 8) {
                    Button {
                        draft = store.settings.promptText
                        dirty = false
                    } label: {
                        Label("还原", systemImage: "arrow.uturn.backward").font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    Button {
                        UIPasteboard.general.string = draft
                        saved = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            saved = false
                        }
                    } label: {
                        Label(saved ? "已复制" : "复制", systemImage: "doc.on.doc").font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    Button {
                        draft = ""
                    } label: {
                        Label("清空", systemImage: "trash").font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.err)
                    Spacer()
                }
            }
        }
    }

    private var presetCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "预设")
            ForEach(Presets.alternatives, id: \.title) { item in
                Button {
                    draft = item.body
                    dirty = true
                    save()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 12, weight: .semibold))
                            Text(item.body).font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.7)).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "arrow.down.circle").foregroundStyle(Theme.accent)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @MainActor private func save() {
        store.updateSettings { $0.promptText = draft }
        dirty = false
        store.log("系统提示词已保存（\(store.settings.promptMode.label)）", .ok)
    }
}
