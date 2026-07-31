import SwiftUI

/// 图标按钮样式，参照 CodeEdit 的 IconButtonStyle。
/// 统一 24×24pt 尺寸，14.5pt 图标，支持 active/pressed 状态。
struct IconButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var font: Font = .system(size: 14.5)
    var size: CGSize = CGSize(width: 24, height: 24)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .symbolVariant(isActive ? .fill : .none)
            .foregroundColor(isActive ? .accentColor : .secondary)
            .frame(width: size.width, height: size.height)
            // Without this the hit area is just the SF Symbol's drawn glyph —
            // a 12pt "plus" is two thin strokes, so most clicks inside the
            // 28×28 frame land on nothing and the button appears dead.
            .contentShape(Rectangle())
            .brightness(configuration.isPressed ? -0.1 : 0)
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static func icon(
        isActive: Bool = false,
        font: Font? = nil,
        size: CGFloat = 24
    ) -> IconButtonStyle {
        IconButtonStyle(
            isActive: isActive,
            font: font ?? .system(size: 14.5),
            size: CGSize(width: size, height: size)
        )
    }
}
