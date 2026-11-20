import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

// MARK: - 主题

extension Theme {
    /// 分隔线
    static let line = Color.primary.opacity(0.065)
    /// 轻填充（分段控件底、搜索框底）
    static let soft = Color.primary.opacity(0.045)
    /// 卡片圆角
    static let cardRadius: CGFloat = 16
    /// 行高
    static let rowPadH: CGFloat = 14
    static let rowPadV: CGFloat = 11
}

// MARK: - 页面骨架

struct Screen<Content: View>: View {
    let title: String
    let trailing: AnyView?
    let content: Content

    init(_ title: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    content
                }
                .padding(.horizontal, 15)
                .padding(.top, 4)
                .padding(.bottom, 30)
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let trailing = trailing {
                    ToolbarItem(placement: .navigationBarTrailing) { trailing }
                }
            }
        }
    }
}

// MARK: - 卡片组

struct Panel<Content: View>: View {
    let title: String?
    let note: String?
    let content: Content

    init(_ title: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title = title {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.9))
                    .padding(.horizontal, 5)
            }
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .fill(Theme.card)
                )
            noteView
        }
    }
}

extension Panel {
    @ViewBuilder
    var noteView: some View {
        if let note = note {
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .padding(.horizontal, 5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 行

struct InfoRow<Trailing: View>: View {
    let icon: String?
    let iconTint: Color
    let title: String
    let subtitle: String?
    let trailing: Trailing
    var showChevron: Bool
    var destructive: Bool

    init(_ title: String,
         subtitle: String? = nil,
         icon: String? = nil,
         iconTint: Color = Theme.accent,
         showChevron: Bool = false,
         destructive: Bool = false,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.iconTint = iconTint
        self.showChevron = showChevron
        self.destructive = destructive
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 11) {
            if let icon = icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .fill(iconTint.opacity(0.13))
                        .frame(width: 29, height: 29)
                    Image(systemName: icon)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
            }
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(destructive ? Theme.err : Color.primary)
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary.opacity(0.8))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            trailing
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
        }
        .padding(.horizontal, Theme.rowPadH)
        .padding(.vertical, Theme.rowPadV)
        .contentShape(Rectangle())
    }
}

extension InfoRow where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, icon: String? = nil,
         iconTint: Color = Theme.accent, showChevron: Bool = false, destructive: Bool = false) {
        self.init(title, subtitle: subtitle, icon: icon, iconTint: iconTint,
                  showChevron: showChevron, destructive: destructive, trailing: { EmptyView() })
    }
}

/// 可点击的行（带按下反馈）
struct TapRow<Content: View>: View {
    let action: () -> Void
    let content: Content
    @State private var pressed = false

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .background(pressed ? Theme.soft : Color.clear)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true } }
                .onEnded { _ in pressed = false }
        )
    }
}

struct RowDivider: View {
    var inset: CGFloat = Theme.rowPadH
    var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 0.7)
            .padding(.leading, inset)
    }
}

// MARK: - 二维码

enum QRCode {
    static func image(from text: String, scale: CGFloat = 12) -> UIImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct QRCodeView: View {
    let text: String
    var size: CGFloat = 208

    var body: some View {
        Group {
            if let image = QRCode.image(from: text) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.soft)
                    .overlay(Text("二维码生成失败").font(.system(size: 12)).foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }
}

// MARK: - 可复制字段

struct CopyField: View {
    let label: String
    let value: String
    var mono = true
    var onCopy: (() -> Void)? = nil
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.85))
                Text(value)
                    .font(.system(size: 12.5, weight: .medium,
                                  design: mono ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                UIPasteboard.general.string = value
                onCopy?()
                copied = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(copied ? Theme.ok : Theme.accent)
                    .frame(width: 29, height: 29)
                    .background(
                        Circle().fill(copied ? Theme.ok.opacity(0.13) : Theme.accent.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.rowPadH)
        .padding(.vertical, 9)
    }
}

// MARK: - 空态

struct EmptyHint: View {
    let icon: String
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(Color.secondary.opacity(0.5))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.accent.opacity(0.13)))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }
}

// MARK: - 分段控件

struct SegmentedItem<T: Hashable> {
    let value: T
    let label: String
    init(_ value: T, _ label: String) {
        self.value = value
        self.label = label
    }
}

struct SegmentedBar<T: Hashable>: View {
    let items: [SegmentedItem<T>]
    @Binding var selection: T

    init(items: [(T, String)], selection: Binding<T>) {
        self.items = items.map { SegmentedItem($0.0, $0.1) }
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { pair in
                let item = pair.element
                let active = item.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = item.value }
                } label: {
                    Text(item.label)
                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6.5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Theme.accent : Color.clear)
                        )
                        .foregroundStyle(active ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.soft))
    }
}

// MARK: - 主按钮

struct PrimaryButton: View {
    let title: String
    let icon: String?
    var enabled = true
    var tint: LinearGradient? = nil
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(.system(size: 13.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint ?? LinearGradient(colors: [Theme.accent, Theme.accent],
                                                startPoint: .leading, endPoint: .trailing))
            )
            .foregroundStyle(.white)
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 数值

enum Num {
    /// 积分/计数显示：整数不带小数，小数保留一位
    static func credit(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// 上下文长度缩写
    static func compact(_ v: Int) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", Double(v) / 1_000_000) }
        if v >= 1000 { return String(format: "%.0fK", Double(v) / 1000) }
        return "\(v)"
    }
}
