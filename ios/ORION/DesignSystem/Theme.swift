import SwiftUI

// ╔══════════════════════════════════════════════════════════════╗
// ║  O.R.I.O.N. DESIGN SYSTEM                                     ║
// ║  Единые токены цвета/типографики/отступов для всего UI.       ║
// ╚══════════════════════════════════════════════════════════════╝
//
// Токены больше не константы: они читают активное оформление из
// Models/OrionAppearance.swift (палитра + акцент + форма углов). Поэтому
// смена темы в «Оформлении» перекрашивает весь интерфейс сразу, а не
// требует правок по экранам.
//
// Цветовой хелпер Color(hex:) определён в Views/LockView.swift — здесь не
// дублируем. Применение: ORIONCard() уже использует стекло; кнопки —
// .buttonStyle(OrionActionButtonStyle(role:)) или OrionGlassButtonStyle();
// фон экрана — .orionBackground(); секция-заголовок — .orionSectionLabel().
// Глобальный вид навигации/таб-бара ставится в OrionTheme.configureAppearance()
// (вызов в ORIONApp и при каждой смене оформления).

enum OrionTheme {

    private static var appearance: OrionAppearance { OrionAppearance.shared }
    private static var palette: OrionPalette { appearance.palette }

    // MARK: - Палитра (семантические токены)

    /// Базовый фон приложения.
    static var bg: Color            { Color(hex: palette.bg) }
    static var bgElevated: Color    { Color(hex: palette.bgElevated) }
    /// Поверхность карточек.
    static var surface: Color       { Color(hex: palette.surface) }
    static var surfaceHi: Color     { Color(hex: palette.surfaceHi) }
    /// Границы.
    static var border: Color        { Color(hex: palette.border) }
    static var borderStrong: Color  { Color(hex: palette.borderStrong) }

    /// Бренд-акцент (по умолчанию cyan — историческая идентичность приложения).
    static var accent: Color        { appearance.accentColor }
    /// Тёмный край акцентного градиента.
    static var accentDeep: Color    { appearance.accentDeepColor }
    /// Историческое имя того же токена (осталось ради старых вызовов).
    static var accentDim: Color     { accentDeep }

    /// Статусные цвета. На светлой теме берём более глубокие оттенки —
    /// пастель на белом фоне читается плохо.
    static var success: Color { Color(hex: palette.isLight ? "15803D" : "22C55E") }
    static var warning: Color { Color(hex: palette.isLight ? "B45309" : "F59E0B") }
    static var danger: Color  { Color(hex: palette.isLight ? "B91C1C" : "EF4444") }

    /// Текст.
    static var textPrimary: Color   { Color(hex: palette.textPrimary) }
    static var textSecondary: Color { Color(hex: palette.textSecondary) }
    static var textTertiary: Color  { Color(hex: palette.textTertiary) }

    // MARK: - Градиенты

    /// Фон экрана: мягкий вертикальный градиент вместо плоского цвета.
    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [bg, bgElevated, bg],
            startPoint: .top, endPoint: .bottom)
    }

    /// Поверхность карточки — тонкий градиент для «глубины».
    static var cardGradient: LinearGradient {
        LinearGradient(
            colors: [surface, surface.orionDarkened(palette.isLight ? -0.02 : 0.18)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Заливка основной (акцентной) кнопки.
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Метрики

    /// Скругления зависят от выбранной формы углов («Строгие/Мягкие/Круглые»).
    enum Radius {
        private static var k: CGFloat { OrionAppearance.shared.corners.scale }
        static var card: CGFloat   { 16 * k }
        static var button: CGFloat { 12 * k }
        static var chip: CGFloat   { 10 * k }
    }

    enum Space  { static let xs: CGFloat = 6; static let sm: CGFloat = 10; static let md: CGFloat = 16; static let lg: CGFloat = 24 }

    // MARK: - Глобальный вид навигации/таб-бара

    /// Настраивает UINavigationBar и UITabBar под активную палитру.
    /// Вызывается при старте и при каждой смене оформления.
    static func configureAppearance() {
        let bgColor = UIColor(bg)
        let accentColor = UIColor(accent)

        // Tab bar — полупрозрачный, чтобы фон/обои просвечивали.
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        tab.backgroundColor = bgColor.withAlphaComponent(palette.isLight ? 0.75 : 0.82)
        let sel = tab.stackedLayoutAppearance.selected
        sel.iconColor = accentColor
        sel.titleTextAttributes = [.foregroundColor: accentColor]
        let norm = tab.stackedLayoutAppearance.normal
        norm.iconColor = UIColor(textTertiary)
        norm.titleTextAttributes = [.foregroundColor: UIColor(textTertiary)]
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        // Nav bar
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        nav.backgroundColor = bgColor.withAlphaComponent(palette.isLight ? 0.75 : 0.82)
        nav.titleTextAttributes = [.foregroundColor: UIColor(textPrimary)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(textPrimary)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}

// MARK: - Модификаторы

extension View {
    /// Фон экрана на всю площадь: градиент, сияние, ровный цвет или обои.
    func orionBackground() -> some View {
        ZStack {
            OrionScreenBackground()
            self
        }
    }

    /// Заголовок секции: капс, трекинг, акцентный цвет.
    func orionSectionLabel() -> some View {
        self.font(.caption.weight(.semibold))
            .foregroundColor(OrionTheme.accent)
            .textCase(.uppercase)
            .tracking(1.2)
    }
}

// MARK: - Стили кнопок

/// Универсальная кнопка действия с ролью — один тип стиля, чтобы можно было
/// переключать вид условием (SwiftUI не допускает разные типы ButtonStyle в
/// тернарном операторе). role: .primary | .danger | .success.
struct OrionActionButtonStyle: ButtonStyle {
    enum Role { case primary, danger, success }
    var role: Role = .primary

    @ObservedObject private var appearance = OrionAppearance.shared

    private var gradient: LinearGradient {
        switch role {
        case .primary: return OrionTheme.accentGradient
        case .danger:  return LinearGradient(colors: [OrionTheme.danger, OrionTheme.danger.orionDarkened(0.3)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
        case .success: return LinearGradient(colors: [OrionTheme.success, OrionTheme.success.orionDarkened(0.3)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
    private var textColor: Color {
        role == .primary ? OrionTheme.accent.orionContrastingText : .white
    }
    private var glow: Color {
        switch role {
        case .primary: return OrionTheme.accent
        case .danger:  return OrionTheme.danger
        case .success: return OrionTheme.success
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: OrionTheme.Radius.button, style: .continuous)
        return configuration.label
            .font(.headline)
            .foregroundColor(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                shape.fill(gradient)
                // Верхний блик — кнопка выглядит выпуклой, как стекло.
                shape.fill(LinearGradient(colors: [.white.opacity(0.30), .clear],
                                          startPoint: .top, endPoint: .center))
                    .blendMode(.plusLighter)
            }
            .clipShape(shape)
            .shadow(color: glow.opacity(0.25), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(appearance.animation(.easeOut(duration: 0.15)), value: configuration.isPressed)
    }
}

/// Вторичная кнопка: приглушённая поверхность, акцентный текст.
struct OrionSecondaryButtonStyle: ButtonStyle {
    @ObservedObject private var appearance = OrionAppearance.shared

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: OrionTheme.Radius.button, style: .continuous)
        return configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(OrionTheme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(LiquidGlass(shape: shape, tint: OrionTheme.accent, strength: 0.8))
            .clipShape(shape)
            .overlay(shape.stroke(OrionTheme.border, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(appearance.animation(.easeOut(duration: 0.15)), value: configuration.isPressed)
    }
}
