import SwiftUI
import UIKit

/// 请求日志：每次反代请求的模型、上游链接、token 消耗、耗时。
struct RequestLogView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var showClear = false
    @State private var expanded: Set<UUID> = []

    enum Filter: String, CaseIterable {
        case all = "全部"
        case ok = "成功"
        case failed = "失败"
    }

    private var filtered: [RequestLog] {
        var list = store.requestLogs
        switch filter {
        case .all: break
        case .ok: list = list.filter { $0.ok }
        case .failed: list = list.filter { !$0.ok }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.model.lowercased().contains(q)
                || $0.upstreamURL.lowercased().contains(q)
                || $0.account.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                summaryBar
                Divider().opacity(0.5)
                searchBar
                if filtered.isEmpty {
                    Spacer()
                    EmptyHint(icon: "list.bullet.rectangle",
                              title: store.requestLogs.isEmpty ? "还没有请求记录" : "没有匹配的记录",
                              detail: store.requestLogs.isEmpty
                                  ? "客户端发起一次对话后，这里会记录模型、链接与 token 消耗"
                                  : "换个关键词或筛选条件")
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filtered) { log in
                                logCard(log)
                            }
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                    }
                }
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("请求日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(store.requestLogs.isEmpty)
                }
            }
            .alert("清空请求日志？", isPresented: $showClear) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    store.clearRequestLogs()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            } message: {
                Text("将删除全部 \(store.requestLogs.count) 条记录，无法恢复。")
            }
        }
    }

    // MARK: - 汇总

    private var summaryBar: some View {
        let s = store.requestSummary()
        return HStack(spacing: 0) {
            stat("请求", "\(s.count)", Theme.accent)
            divider
            stat("Tokens", Num.compact(s.tokens), Theme.accent2)
            divider
            stat("失败", "\(s.failed)", s.failed > 0 ? Theme.err : Theme.ok)
            divider
            stat("平均", s.avgMs > 0 ? "\(s.avgMs)ms" : "—", Theme.warn)
        }
        .padding(.vertical, 10)
        .background(Theme.card)
    }

    private func stat(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 0.7, height: 22)
    }

    // MARK: - 搜索与筛选

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                TextField("搜索模型 / 链接 / 账号", text: $query)
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

            SegmentedBar(items: Filter.allCases.map { ($0, $0.rawValue) },
                         selection: $filter)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
    }

    // MARK: - 记录卡

    private func logCard(_ log: RequestLog) -> some View {
        let isExpanded = expanded.contains(log.id)
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Circle()
                    .fill(log.ok ? Theme.ok : Theme.err)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 5) {
                        Text(log.model)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                        Text(log.dialect)
                            .font(.system(size: 8.5, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.accent.opacity(0.12)))
                            .foregroundStyle(Theme.accent)
                        if log.streamed {
                            Image(systemName: "waveform")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.secondary.opacity(0.6))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(log.upstreamURL)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(log.tokenSummary)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(log.totalTokens > 0 ? Color.primary : Color.secondary.opacity(0.6))
                    Text("\(log.stamp) · \(log.elapsedText)")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Color.secondary.opacity(0.65))
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isExpanded { expanded.remove(log.id) } else { expanded.insert(log.id) }
                }
            }

            if isExpanded {
                RowDivider(inset: 13)
                VStack(alignment: .leading, spacing: 6) {
                    detailRow("客户端模型", log.model)
                    detailRow("上游链接", log.upstreamURL)
                    detailRow("账号", log.account)
                    detailRow("状态", "\(log.status)\(log.ok ? " 成功" : "")")
                    detailRow("Tokens", log.tokenSummary)
                    if log.reasoningTokens > 0 {
                        detailRow("推理 tokens", "\(log.reasoningTokens)")
                    }
                    detailRow("耗时", log.elapsedText)
                    if !log.error.isEmpty {
                        detailRow("错误", log.error, tint: Theme.err)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.card))
    }

    private func detailRow(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.85))
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
