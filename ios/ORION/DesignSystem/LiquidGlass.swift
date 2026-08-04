import SwiftUI
import UIKit

// ╔══════════════════════════════════════════════════════════════╗
// ║  LIQUID GLASS — «жидкое стекло» в духе Apple                  ║
// ║  Материал + бликующая кромка + мягкое свечение под пальцем.  ║
// ╚══════════════════════════════════════════════════════════════╝
//
// Честно о реализации: настоящий `glassEffect` из iOS 26 здесь применить
// нельзя — приложение собирается под iOS 16 (Xcode 16.4 в CI такого API
// ещё не знает). Поэтому эффект собран вручную из того, что есть с iOS 15:
// системный материал (реальное размытие фона) + слой бликов + световая
// кромка. Визуально это очень близко, работает на всех поддерживаемых
// версиях и не ломает сборку.
//
// Сила эффекта берётся из OrionAppearance.glass: «Выкл» возвращает
// обычную непрозрачную карточку, «Мягко» — половину бликов,
// «Жидкое стекло» — полный эффект.

// MARK: - Подложка

/// Стеклянная подложка произвольной формы.
struct LiquidGlass<S: Shape>: View {
    let shape: S
    /// Лёгкая подкраска стекла (акцент для важных блоков).
    var tint: Color = .clear
    /// Множитель силы эффекта поверх глобального уровня (0…1).
    var strength: Double = 1
    /// Рисовать светящуюся кромку.
    var rim: Bool = true

    @ObservedObject private var appearance = OrionAppearance.shared

    private var level: Double { appearance.glass.intensity * max(0, min(1, strength)) }

    var body: some View {
        ZStack {
            if level <= 0 {
                // Стекло выключено — обычная плотная поверхность.
                shape.fill(OrionTheme.cardGradient)
            } else {
                // 1. Настоящее размытие того, что под карточкой.
                shape.fill(.ultraThinMaterial)

                // 2. Плотность: на светлой теме стекло светлее, на тёмной — глубже.
                shape.fill(
                    LinearGradient(
                        colors: [
                            OrionTheme.surface.opacity(appearance.isLight ? 0.42 : 0.55),
                            OrionTheme.surface.opacity(appearance.isLight ? 0.18 : 0.30),
                        ],
                        startPoint: .top, endPoint: .bottom)
                )

                // 3. Подкраска (для акцентных блоков).
                if tint != .clear {
                    shape.fill(tint.opacity(0.16 * level))
                }

                // 4. Блик: свет падает сверху-слева, к низу сходит на нет.
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.28 * level),
                            Color.white.opacity(0.06 * level),
                            Color.clear,
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .blendMode(.plusLighter)

                // 5. Световая кромка — то, что делает стекло «толстым».
                if rim {
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.55 * level),
                                Color.white.opacity(0.10 * level),
                                OrionTheme.accent.opacity(0.22 * level),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
                }
            }
        }
        .compositingGroup()
    }
}

// MARK: - Модификаторы

extension View {
    /// Положить содержимое на стеклянную карточку со скруглением.
    func liquidGlass(cornerRadius: CGFloat? = nil,
                     tint: Color = .clear,
                     strength: Double = 1,
                     shadow: Bool = true) -> some View {
        let r = cornerRadius ?? OrionTheme.Radius.card
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        return self
            .background(LiquidGlass(shape: shape, tint: tint, strength: strength))
            .clipShape(shape)
            .shadow(color: Color.black.opacity(shadow ? (OrionAppearance.shared.isLight ? 0.10 : 0.35) : 0),
                    radius: shadow ? 12 : 0, x: 0, y: shadow ? 6 : 0)
    }

    /// Стеклянная «пилюля» — для чипов, бейджей и плавающих панелей.
    func glassPill(tint: Color = .clear, strength: Double = 1) -> some View {
        background(LiquidGlass(shape: Capsule(style: .continuous), tint: tint, strength: strength))
            .clipShape(Capsule(style: .continuous))
    }
}

// MARK: - Кнопка на стекле

/// Кнопка, которая ведёт себя как физическое стекло: при нажатии
/// слегка вдавливается и ярче бликует.
struct OrionGlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var prominent: Bool = false

    @ObservedObject private var appearance = OrionAppearance.shared

    func makeBody(configuration: Configuration) -> some View {
        let accent = tint ?? OrionTheme.accent
        let shape = RoundedRectangle(cornerRadius: OrionTheme.Radius.button, style: .continuous)
        return configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(prominent ? accent.orionContrastingText : accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background {
                if prominent {
                    shape.fill(LinearGradient(colors: [accent, OrionTheme.accentDeep],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                    shape.fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                              startPoint: .top, endPoint: .center))
                        .blendMode(.plusLighter)
                } else {
                    LiquidGlass(shape: shape, tint: accent, strength: 0.9)
                }
            }
            .clipShape(shape)
            .overlay {
                if configuration.isPressed {
                    shape.fill(Color.white.opacity(0.10))
                }
            }
            .shadow(color: accent.opacity(prominent ? 0.28 : 0.12),
                    radius: configuration.isPressed ? 6 : 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(appearance.animation(.easeOut(duration: 0.15)), value: configuration.isPressed)
    }
}

// MARK: - Фон экрана

/// Фон приложения: градиент, «сияние», ровный цвет или обои пользователя.
/// Живёт отдельным типом, потому что рисуется под каждым экраном и должен
/// одинаково реагировать на смену оформления.
struct OrionScreenBackground: View {
    @ObservedObject private var appearance = OrionAppearance.shared

    var body: some View {
        ZStack {
            switch appearance.backdrop {
            case .flat:
                OrionTheme.bg
            case .gradient:
                OrionTheme.backgroundGradient
            case .glow:
                OrionTheme.backgroundGradient
                ambientGlow
            case .wallpaper:
                if let image = appearance.wallpaper {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: CGFloat(appearance.wallpaperBlur))
                        .overlay(OrionTheme.bg.opacity(appearance.wallpaperDim))
                } else {
                    OrionTheme.backgroundGradient
                }
            }
        }
        .ignoresSafeArea()
    }

    /// Медленно «дышащие» пятна акцента — как подсветка за стеклом.
    @ViewBuilder
    private var ambientGlow: some View {
        if appearance.ambientMotion && appearance.animationsEnabled {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    draw(ctx: &ctx, size: size, t: t)
                }
                .allowsHitTesting(false)
            }
        } else {
            Canvas { ctx, size in
                draw(ctx: &ctx, size: size, t: 0)
            }
            .allowsHitTesting(false)
        }
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let accent = OrionTheme.accent
        let blobs: [(phase: Double, radius: Double, color: Color)] = [
            (0.0, 0.55, accent),
            (2.1, 0.42, OrionTheme.accentDeep),
            (4.3, 0.35, accent),
        ]
        ctx.addFilter(.blur(radius: 60))
        for blob in blobs {
            let x = 0.5 + 0.32 * cos(t * 0.06 + blob.phase)
            let y = 0.35 + 0.30 * sin(t * 0.045 + blob.phase * 1.3)
            let r = size.width * blob.radius * 0.5
            let rect = CGRect(x: x * size.width - r, y: y * size.height - r,
                              width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect),
                     with: .color(blob.color.opacity(OrionAppearance.shared.isLight ? 0.10 : 0.16)))
        }
    }
}
