import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

// MARK: - 主题扩展

extension Theme {
    static let line = Color.primary.opacity(0.07)
    static let soft = Color.primary.opacity(0.05)
}

// MARK: - 分组卡片（带标题 + 说明，替代 Settings 里的 Section）

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
        VStack(alignment: .leading, spacing: 8) {
            if let title = title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1))
            if let note = note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 列表行

struct InfoRow<Trailing: View>: View {
    let icon: String?
    let iconTint: Color
    let title: String
    let subtitle: String?
    let trailing: Trailing
    var showChevron = false

    init(_ title: String,
         subtitle: String? = nil,
         icon: String? = nil,
         iconTint: Color = Theme.accent,
         showChevron: Bool = false,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.iconTint = iconTint
        self.showChevron = showChevron
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 11) {
            if let icon = icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(iconTint.opacity(0.14))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14))
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            trailing
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

extension InfoRow where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, icon: String? = nil,
         iconTint: Color = Theme.accent, showChevron: Bool = false) {
        self.init(title, subtitle: subtitle, icon: icon, iconTint: iconTint,
                  showChevron: showChevron, trailing: { EmptyView() })
    }
}

/// 行间分隔线（左对齐，缩进对齐文字）
struct RowDivider: View {
    var inset: CGFloat = 14
    var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 0.7)
            .padding(.leading, inset)
    }
}

// MARK: - 二维码

enum QRCode {
    static func image(from text: String, scale: CGFloat = 10) -> UIImage? {
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
    var size: CGFloat = 200

    var body: some View {
        Group {
            if let image = QRCode.image(from: text) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.soft)
                    .overlay(Text("二维码生成失败").font(.system(size: 12)).foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 可复制字段

struct CopyField: View {
    let label: String
    let value: String
    var mono = true
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: mono ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                UIPasteboard.general.string = value
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_300_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(copied ? Theme.ok : Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.accent.opacity(copied ? 0 : 0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - 空态

struct EmptyHint: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.secondary.opacity(0.6))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
    }
}

// MARK: - 分段选择器（自绘，避免 Picker(segmented) 宽度问题）

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
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { pair in
                let item = pair.element
                let active = item.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selection = item.value }
                } label: {
                    Text(item.label)
                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(active ? Theme.accent : Color.clear)
                        )
                        .foregroundStyle(active ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.soft))
    }
}
