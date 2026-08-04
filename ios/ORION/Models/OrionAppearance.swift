import SwiftUI
import Combine
import UIKit

// ╔══════════════════════════════════════════════════════════════╗
// ║  O.R.I.O.N. APPEARANCE — кастомизация оформления             ║
// ║  Одно место, где живут выбор палитры, акцента, обоев,         ║
// ║  «жидкого стекла», скруглений и размера текста.               ║
// ╚══════════════════════════════════════════════════════════════╝
//
// Дизайн-система (DesignSystem/Theme.swift) больше не хранит цвета сама —
// её токены читают активную палитру отсюда. Поэтому смена темы меняет
// весь интерфейс, а не отдельный экран.
//
// Реактивность: экраны, которые должны перекрашиваться на лету, держат
// `@ObservedObject private var appearance = OrionAppearance.shared`.
// Этого достаточно — тело перерисуется, а токены отдадут новые цвета.
//
// Хранение: тот же App Group, что и у AppSettings, поэтому оформление
// переживает перезапуск и доступно виджету.

// MARK: - Палитра

/// Полный набор фоновых/текстовых цветов темы. Акцент задаётся отдельно,
/// чтобы любую палитру можно было сочетать с любым акцентом.
struct OrionPalette: Identifiable, Equatable {
    let id: String
    let title: String
    /// Светлая тема требует другого системного вида контролов.
    let isLight: Bool

    let bg: String
    let bgElevated: String
    let surface: String
    let surfaceHi: String
    let border: String
    let borderStrong: String
    let textPrimary: String
    let textSecondary: String
    let textTertiary: String

    static let all: [OrionPalette] = [
        OrionPalette(
            id: "midnight", title: "Полночь", isLight: false,
            bg: "020617", bgElevated: "0A1120", surface: "0F172A", surfaceHi: "1E293B",
            border: "233247", borderStrong: "334155",
            textPrimary: "F8FAFC", textSecondary: "94A3B8", textTertiary: "64748B"),
        OrionPalette(
            id: "obsidian", title: "Обсидиан", isLight: false,
            bg: "000000", bgElevated: "090909", surface: "111111", surfaceHi: "1C1C1E",
            border: "2C2C2E", borderStrong: "3A3A3C",
            textPrimary: "FFFFFF", textSecondary: "A1A1AA", textTertiary: "71717A"),
        OrionPalette(
            id: "indigo", title: "Индиго", isLight: false,
            bg: "0B1026", bgElevated: "141B3C", surface: "1A2145", surfaceHi: "273060",
            border: "2E3A6B", borderStrong: "3F4C86",
            textPrimary: "F5F3FF", textSecondary: "A5B4FC", textTertiary: "818CF8"),
        OrionPalette(
            id: "graphite", title: "Графит", isLight: false,
            bg: "121212", bgElevated: "191919", surface: "202020", surfaceHi: "2A2A2A",
            border: "343434", borderStrong: "454545",
            textPrimary: "F5F5F5", textSecondary: "A3A3A3", textTertiary: "737373"),
        OrionPalette(
            id: "moss", title: "Хвоя", isLight: false,
            bg: "07130F", bgElevated: "0C1D17", surface: "102620", surfaceHi: "17352C",
            border: "1E4438", borderStrong: "2A5A4A",
            textPrimary: "ECFDF5", textSecondary: "9CC5B4", textTertiary: "6E9686"),
        OrionPalette(
            id: "daylight", title: "День", isLight: true,
            bg: "F4F6FB", bgElevated: "FFFFFF", surface: "FFFFFF", surfaceHi: "EEF2F9",
            border: "D8E0EC", borderStrong: "BCC7D8",
            textPrimary: "0F172A", textSecondary: "51607A", textTertiary: "8794AB"),
        OrionPalette(
            id: "parchment", title: "Пергамент", isLight: true,
            bg: "F7F3EC", bgElevated: "FFFCF6", surface: "FFFCF6", surfaceHi: "F0E9DC",
            border: "E2D8C6", borderStrong: "CDBFA6",
            textPrimary: "2B2118", textSecondary: "6B5B48", textTertiary: "97866F"),
    ]

    static func named(_ id: String) -> OrionPalette {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - Акцент

/// Бренд-цвет: пара оттенков для градиента кнопок и подсветок.
struct OrionAccent: Identifiable, Equatable {
    let id: String
    let title: String
    let hex: String
    let deepHex: String

    static let all: [OrionAccent] = [
        OrionAccent(id: "cyan",   title: "Орион",   hex: "22D3EE", deepHex: "0891B2"),
        OrionAccent(id: "aurora", title: "Аврора",  hex: "34D399", deepHex: "059669"),
        OrionAccent(id: "ice",    title: "Лёд",     hex: "60A5FA", deepHex: "2563EB"),
        OrionAccent(id: "violet", title: "Аметист", hex: "A78BFA", deepHex: "7C3AED"),
        OrionAccent(id: "rose",   title: "Сакура",  hex: "F472B6", deepHex: "DB2777"),
        OrionAccent(id: "sunset", title: "Закат",   hex: "FB7185", deepHex: "E11D48"),
        OrionAccent(id: "amber",  title: "Янтарь",  hex: "FBBF24", deepHex: "D97706"),
        OrionAccent(id: "lime",   title: "Лайм",    hex: "A3E635", deepHex: "65A30D"),
    ]

    static func named(_ id: String) -> OrionAccent {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - Фон экрана

/// Чем залит фон: градиентом активной палитры, «сиянием» с акцентом,
/// ровным цветом или пользовательскими обоями из галереи.
enum OrionBackdrop: String, CaseIterable, Identifiable {
    case gradient, glow, flat, wallpaper
    var id: String { rawValue }

    var title: String {
        switch self {
        case .gradient:  return "Градиент"
        case .glow:      return "Сияние"
        case .flat:      return "Ровный"
        case .wallpaper: return "Обои"
        }
    }
}

/// Насколько сильно интерфейс «стеклянный» (Liquid Glass).
enum OrionGlassLevel: String, CaseIterable, Identifiable {
    case off, soft, liquid
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:    return "Выкл"
        case .soft:   return "Мягко"
        case .liquid: return "Жидкое стекло"
        }
    }

    /// Множитель силы бликов/прозрачности.
    var intensity: Double {
        switch self {
        case .off:    return 0
        case .soft:   return 0.55
        case .liquid: return 1
        }
    }
}

/// Форма углов карточек и кнопок.
enum OrionCornerStyle: String, CaseIterable, Identifiable {
    case sharp, soft, round
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sharp: return "Строгие"
        case .soft:  return "Мягкие"
        case .round: return "Круглые"
        }
    }

    var scale: CGFloat {
        switch self {
        case .sharp: return 0.4
        case .soft:  return 1.0
        case .round: return 1.7
        }
    }
}

// MARK: - Состояние оформления

final class OrionAppearance: ObservableObject {

    static let shared = OrionAppearance()

    private let defaults: UserDefaults

    /// Счётчик изменений: экраны, которым нужна принудительная
    /// перерисовка (например, UIKit-карта), вешают на него `.id()`.
    @Published private(set) var revision: Int = 0

    @Published var paletteID: String {
        didSet { defaults.set(paletteID, forKey: "ui.palette"); applied() }
    }
    @Published var accentID: String {
        didSet { defaults.set(accentID, forKey: "ui.accent"); applied() }
    }
    /// Свой цвет акцента (hex без #). Пустая строка — используется пресет.
    @Published var customAccentHex: String {
        didSet { defaults.set(customAccentHex, forKey: "ui.accentHex"); applied() }
    }
    @Published var backdrop: OrionBackdrop {
        didSet { defaults.set(backdrop.rawValue, forKey: "ui.backdrop"); applied() }
    }
    @Published var glass: OrionGlassLevel {
        didSet { defaults.set(glass.rawValue, forKey: "ui.glass"); applied() }
    }
    @Published var corners: OrionCornerStyle {
        didSet { defaults.set(corners.rawValue, forKey: "ui.corners"); applied() }
    }
    /// Прозрачность обоев под интерфейсом (0.15…1).
    @Published var wallpaperDim: Double {
        didSet { defaults.set(wallpaperDim, forKey: "ui.wallDim"); applied() }
    }
    /// Размытие обоев в точках (0…30).
    @Published var wallpaperBlur: Double {
        didSet { defaults.set(wallpaperBlur, forKey: "ui.wallBlur"); applied() }
    }
    /// Индекс размера текста внутри `dynamicSizes`.
    @Published var textSizeIndex: Int {
        didSet { defaults.set(textSizeIndex, forKey: "ui.textSize"); applied() }
    }
    @Published var animationsEnabled: Bool {
        didSet { defaults.set(animationsEnabled, forKey: "ui.animations"); applied() }
    }
    /// Живой фон: медленно дышащее сияние акцента.
    @Published var ambientMotion: Bool {
        didSet { defaults.set(ambientMotion, forKey: "ui.ambient"); applied() }
    }

    // MARK: Питомец (см. Models/OrionPet.swift)

    @Published var petsEnabled: Bool {
        didSet { defaults.set(petsEnabled, forKey: "pet.enabled"); applied() }
    }
    @Published var petSpeciesID: String {
        didSet { defaults.set(petSpeciesID, forKey: "pet.species"); applied() }
    }
    @Published var petName: String {
        didSet { defaults.set(petName, forKey: "pet.name"); applied() }
    }
    /// Окрас шерсти, свой у каждого вида: `species.rawValue → "RRGGBB"`.
    /// Общим полем это быть не может — рыжий кот, ставший рыжим пингвином
    /// при смене вида, выглядит как баг, а не как настройка.
    @Published var petFurHexes: [String: String] {
        didSet { defaults.set(petFurHexes, forKey: "pet.furHexes"); applied() }
    }
    /// Питомец сопровождает и на карте (играет с точкой).
    @Published var petOnMap: Bool {
        didSet { defaults.set(petOnMap, forKey: "pet.map"); applied() }
    }
    /// Питомец дремлет калачиком возле кнопки SOS.
    @Published var petGuardsSOS: Bool {
        didSet { defaults.set(petGuardsSOS, forKey: "pet.sos"); applied() }
    }

    /// Обои пользователя. Хранятся файлом в контейнере App Group,
    /// в памяти держим уже раскодированную картинку.
    @Published private(set) var wallpaper: UIImage?

    private init() {
        let d = UserDefaults(suiteName: AppSettings.appGroup) ?? .standard
        self.defaults = d

        self.paletteID       = d.string(forKey: "ui.palette") ?? "midnight"
        self.accentID        = d.string(forKey: "ui.accent")  ?? "cyan"
        self.customAccentHex = d.string(forKey: "ui.accentHex") ?? ""
        self.backdrop        = OrionBackdrop(rawValue: d.string(forKey: "ui.backdrop") ?? "") ?? .gradient
        self.glass           = OrionGlassLevel(rawValue: d.string(forKey: "ui.glass") ?? "") ?? .soft
        self.corners         = OrionCornerStyle(rawValue: d.string(forKey: "ui.corners") ?? "") ?? .soft
        self.wallpaperDim    = (d.object(forKey: "ui.wallDim")  as? Double) ?? 0.45
        self.wallpaperBlur   = (d.object(forKey: "ui.wallBlur") as? Double) ?? 12
        self.textSizeIndex   = (d.object(forKey: "ui.textSize") as? Int) ?? 2
        self.animationsEnabled = d.object(forKey: "ui.animations") as? Bool ?? true
        self.ambientMotion     = d.object(forKey: "ui.ambient")    as? Bool ?? true

        // Питомец — украшение, а не функция безопасности: по умолчанию выключен.
        self.petsEnabled   = d.object(forKey: "pet.enabled") as? Bool ?? false
        self.petSpeciesID  = d.string(forKey: "pet.species") ?? "cat"
        self.petName       = d.string(forKey: "pet.name") ?? ""
        self.petFurHexes   = d.dictionary(forKey: "pet.furHexes") as? [String: String] ?? [:]
        self.petOnMap      = d.object(forKey: "pet.map") as? Bool ?? true
        self.petGuardsSOS  = d.object(forKey: "pet.sos") as? Bool ?? true

        loadWallpaper()
    }

    // MARK: - Производные значения

    var palette: OrionPalette { OrionPalette.named(paletteID) }

    var accentPreset: OrionAccent { OrionAccent.named(accentID) }

    /// Активный акцент: свой цвет важнее пресета.
    var accentColor: Color {
        customAccentHex.isEmpty ? Color(hex: accentPreset.hex) : Color(hex: customAccentHex)
    }

    /// Тёмный край акцентного градиента. Для своего цвета затемняем его сами.
    var accentDeepColor: Color {
        customAccentHex.isEmpty
            ? Color(hex: accentPreset.deepHex)
            : Color(hex: customAccentHex).orionDarkened(0.35)
    }

    /// Окрас вида: свой, если выбирали, иначе «как нарисовано».
    func petFurHex(for species: PetSpecies) -> String {
        petFurHexes[species.rawValue] ?? species.defaultFurHex
    }

    func setPetFur(_ hex: String, for species: PetSpecies) {
        petFurHexes[species.rawValue] = hex
    }

    var isLight: Bool { palette.isLight }

    var colorScheme: ColorScheme { isLight ? .light : .dark }

    /// Доступные размеры текста (подпись → системный размер).
    static let dynamicSizes: [(title: String, size: DynamicTypeSize)] = [
        ("XS", .xSmall), ("S", .small), ("M", .medium), ("L", .large),
        ("XL", .xLarge), ("XXL", .xxLarge),
    ]

    var dynamicTypeSize: DynamicTypeSize {
        let idx = min(max(textSizeIndex, 0), Self.dynamicSizes.count - 1)
        return Self.dynamicSizes[idx].size
    }

    /// Анимация, уважающая тумблер «анимации» и системное «уменьшить движение».
    func animation(_ base: Animation) -> Animation? {
        guard animationsEnabled, !UIAccessibility.isReduceMotionEnabled else { return nil }
        return base
    }

    // MARK: - Обои

    private var wallpaperURL: URL? { AppSettings.sharedFileURL("wallpaper.jpg") }

    func setWallpaper(_ image: UIImage?) {
        guard let image = image else {
            wallpaper = nil
            if let url = wallpaperURL { try? FileManager.default.removeItem(at: url) }
            if backdrop == .wallpaper { backdrop = .gradient }
            applied()
            return
        }
        // Ужимаем до разумного размера: обои во весь экран, ретина-запас ×2.
        let resized = image.orionFitted(maxSide: 1600)
        wallpaper = resized
        if let url = wallpaperURL, let data = resized.jpegData(compressionQuality: 0.85) {
            try? data.write(to: url, options: .atomic)
        }
        backdrop = .wallpaper
        applied()
    }

    private func loadWallpaper() {
        guard let url = wallpaperURL,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return }
        wallpaper = image
    }

    // MARK: - Применение

    /// Один общий хвост для всех didSet: поднять счётчик и обновить
    /// глобальный вид навигации/таб-бара под новую палитру.
    private func applied() {
        revision &+= 1
        OrionTheme.configureAppearance()
    }

    /// Сбросить оформление к заводскому виду.
    func resetToDefaults() {
        paletteID = "midnight"
        accentID = "cyan"
        customAccentHex = ""
        backdrop = .gradient
        glass = .soft
        corners = .soft
        wallpaperDim = 0.45
        wallpaperBlur = 12
        textSizeIndex = 2
        animationsEnabled = true
        ambientMotion = true
        // Вид и имя питомца — выбор человека, его сброс оформления не трогает;
        // а вот окрасы относятся именно к оформлению.
        petFurHexes = [:]
        setWallpaper(nil)
    }
}

// MARK: - Мелкие помощники

extension Color {
    /// Затемнить цвет (для нижнего края градиента своего акцента).
    /// Отрицательный amount, наоборот, осветляет.
    func orionDarkened(_ amount: Double) -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        let scaled = b * CGFloat(1 - amount)
        return Color(UIColor(hue: h, saturation: s,
                             brightness: min(1, max(0, scaled)), alpha: a))
    }

    /// Цвет в виде «RRGGBB» — в таком виде акцент хранится в настройках.
    var orionHexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "22D3EE" }
        let clamp: (CGFloat) -> Int = { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }

    /// Читаемый текст поверх этого цвета (для акцентных кнопок).
    var orionContrastingText: Color {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
        // Относительная яркость по WCAG-подобной формуле.
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luma > 0.6 ? Color(hex: "0B1220") : .white
    }
}

extension UIImage {
    /// Пропорционально ужать так, чтобы большая сторона была не больше maxSide.
    func orionFitted(maxSide: CGFloat) -> UIImage {
        let side = max(size.width, size.height)
        guard side > maxSide, side > 0 else { return self }
        let k = maxSide / side
        let target = CGSize(width: size.width * k, height: size.height * k)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
