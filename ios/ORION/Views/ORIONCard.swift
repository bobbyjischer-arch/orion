import SwiftUI

/// Базовая карточка O.R.I.O.N. Использует токены дизайн-системы
/// (см. DesignSystem/Theme.swift) и стеклянную подложку
/// (DesignSystem/LiquidGlass.swift): реальное размытие фона, световая
/// кромка, мягкая тень. `accent: true` подсвечивает карточку бренд-цветом
/// (для акцентных блоков вроде тревоги/анализа).
///
/// Если в «Оформлении» стекло выключено, подложка сама превращается в
/// обычную плотную поверхность — вызывающему коду ничего менять не нужно.
struct ORIONCard<Content: View>: View {
    var accent: Bool = false
    let content: Content

    @ObservedObject private var appearance = OrionAppearance.shared

    init(accent: Bool = false, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OrionTheme.Radius.card, style: .continuous)
        return content
            .padding(OrionTheme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LiquidGlass(shape: shape,
                            tint: accent ? OrionTheme.accent : .clear,
                            strength: accent ? 1 : 0.85)
            )
            .clipShape(shape)
            .overlay(
                shape.stroke(accent ? OrionTheme.accent.opacity(0.45) : OrionTheme.border,
                             lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(appearance.isLight ? 0.08 : 0.35),
                    radius: 10, x: 0, y: 5)
    }
}
