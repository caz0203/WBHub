import SwiftUI
import UIKit

enum Theme {
    static let accent = Color(red: 0.27, green: 0.55, blue: 1.0)
    static let accent2 = Color(red: 0.45, green: 0.36, blue: 0.95)
    static let ok = Color(red: 0.18, green: 0.72, blue: 0.46)
    static let warn = Color(red: 0.95, green: 0.65, blue: 0.2)
    static let err = Color(red: 0.92, green: 0.32, blue: 0.35)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let page = Color(uiColor: .systemGroupedBackground)

    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct Card<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1))
    }
}

struct Pill: View {
    let text: String
    let color: Color

    init(text: String, color: Color = Theme.accent) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let hint: String?
    let tint: Color

    init(title: String, value: String, hint: String? = nil, tint: Color = Theme.accent) {
        self.title = title
        self.value = value
        self.hint = hint
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let hint = hint { Text(hint).font(.system(size: 10)).foregroundStyle(Color.secondary.opacity(0.7)).lineLimit(1) }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

struct Toast: View {
    let text: String
    let ok: Bool

    init(text: String, ok: Bool = true) {
        self.text = text
        self.ok = ok
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder((ok ? Theme.ok : Theme.err).opacity(0.35)))
        .foregroundStyle(ok ? Theme.ok : Theme.err)
    }
}
