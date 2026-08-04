import SwiftUI
import PhotosUI

// ╔══════════════════════════════════════════════════════════════╗
// ║  ОФОРМЛЕНИЕ — «настрой под себя», как в Telegram              ║
// ╚══════════════════════════════════════════════════════════════╝
//
// Один экран, где живёт вся кастомизация: тема, акцент (включая свой
// цвет), фон и обои, сила «жидкого стекла», форма углов, размер текста,
// анимации и питомец. Наверху — живой предпросмотр: он собран из тех же
// токенов, что и настоящие экраны, поэтому показывает правду, а не
// нарисованную картинку.
//
// Питомец по умолчанию выключен: это украшение, а не функция
// безопасности (см. `OrionAppearance.petsEnabled`).

struct AppearanceView: View {

    @ObservedObject private var appearance = OrionAppearance.shared
    @ObservedObject private var companion = PetCompanion.shared

    @State private var photoItem: PhotosPickerItem?
    @State private var showReset = false

    var body: some View {
        ZStack {
            OrionScreenBackground()

            ScrollView {
                VStack(spacing: 22) {
                    previewCard
                    paletteSection
                    accentSection
                    backdropSection
                    glassSection
                    shapeSection
                    typeSection
                    motionSection
                    petSection
                    resetSection
                }
                .padding(16)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Оформление")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photoItem) { item in
            loadWallpaper(from: item)
        }
        .confirmationDialog("Вернуть заводское оформление?",
                            isPresented: $showReset, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) {
                withAnimation(appearance.animation(.easeInOut(duration: 0.25))) {
                    appearance.resetToDefaults()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Тема, акцент, фон, обои, стекло и размер текста вернутся к исходным. Настройки питомца останутся.")
        }
    }

    // MARK: - Предпросмотр

    /// Мини-копия настоящего экрана. Собрана из живых токенов —
    /// как только меняется палитра, меняется и она.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(OrionTheme.accentGradient)
                    Image(systemName: "shield.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(OrionTheme.accent.orionContrastingText)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("O.R.I.O.N.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(OrionTheme.textPrimary)
                    Text("Обстановка спокойная")
                        .font(.caption2)
                        .foregroundColor(OrionTheme.textSecondary)
                }

                Spacer()

                Text("AEGIS")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(OrionTheme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .glassPill(tint: OrionTheme.accent)
            }

            // Шкала — как у счётчика подозрения на «Статусе».
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(OrionTheme.surfaceHi)
                    Capsule().fill(OrionTheme.accentGradient)
                        .frame(width: geo.size.width * 0.34)
                }
            }
            .frame(height: 8)

            HStack(spacing: 10) {
                Text("Готово")
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(OrionTheme.accentGradient)
                    .foregroundColor(OrionTheme.accent.orionContrastingText)
                    .font(.subheadline.weight(.semibold))
                    .clipShape(RoundedRectangle(cornerRadius: OrionTheme.Radius.button,
                                                style: .continuous))

                Text("Отмена")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(OrionTheme.accent)
                    .liquidGlass(cornerRadius: OrionTheme.Radius.button,
                                 tint: OrionTheme.accent, strength: 0.8, shadow: false)
            }

            Text("Так будет выглядеть интерфейс — цвета, стекло, углы и размер шрифта.")
                .font(.caption2)
                .foregroundColor(OrionTheme.textTertiary)
        }
        .padding(16)
        .liquidGlass()
        .overlay(alignment: .bottomTrailing) { previewPet }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var previewPet: some View {
        if appearance.petsEnabled {
            PetPreview(species: companion.species, size: 46, tint: companion.furColor)
                .padding(.trailing, 14)
                .offset(y: 14)
        }
    }

    // MARK: - Тема

    private var paletteSection: some View {
        section("Тема", hint: "Светлые темы меняют не только фон: статусные цвета и стекло подстраиваются под них.") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(OrionPalette.all) { palette in
                    Button {
                        apply { appearance.paletteID = palette.id }
                    } label: {
                        paletteCard(palette)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func paletteCard(_ palette: OrionPalette) -> some View {
        let selected = appearance.paletteID == palette.id
        let shape = RoundedRectangle(cornerRadius: OrionTheme.Radius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(hex: palette.bg), Color(hex: palette.bgElevated)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: palette.textPrimary).opacity(0.85))
                        .frame(width: 46, height: 5)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: palette.textSecondary).opacity(0.7))
                        .frame(width: 30, height: 5)
                    Capsule()
                        .fill(appearance.accentColor)
                        .frame(width: 22, height: 7)
                }
                .padding(10)
            }
            .frame(height: 74)
            .clipShape(RoundedRectangle(cornerRadius: OrionTheme.Radius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OrionTheme.Radius.chip, style: .continuous)
                    .stroke(Color(hex: palette.border), lineWidth: 1)
            )

            HStack(spacing: 6) {
                Text(palette.title)
                    .font(.caption.weight(.medium))
                    .foregroundColor(selected ? OrionTheme.accent : OrionTheme.textSecondary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(OrionTheme.accent)
                }
            }
        }
        .padding(10)
        .background(shape.fill(OrionTheme.surface.opacity(selected ? 0.55 : 0.25)))
        .overlay(shape.stroke(selected ? OrionTheme.accent : OrionTheme.border,
                              lineWidth: selected ? 1.5 : 1))
    }

    // MARK: - Акцент

    private var accentSection: some View {
        section("Акцент", hint: "Акцент независим от темы: любой цвет сочетается с любой палитрой.") {
            VStack(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(OrionAccent.all) { accent in
                            Button {
                                apply {
                                    appearance.customAccentHex = ""
                                    appearance.accentID = accent.id
                                }
                            } label: {
                                accentDot(accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }

                ColorPicker(selection: customAccentBinding, supportsOpacity: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Свой цвет")
                            .font(.subheadline)
                            .foregroundColor(OrionTheme.textPrimary)
                        Text(appearance.customAccentHex.isEmpty
                             ? "используется пресет"
                             : "#\(appearance.customAccentHex)")
                            .font(.caption2.monospaced())
                            .foregroundColor(OrionTheme.textTertiary)
                    }
                }

                if !appearance.customAccentHex.isEmpty {
                    Button("Вернуть цвет пресета") {
                        apply { appearance.customAccentHex = "" }
                    }
                    .font(.caption)
                    .foregroundColor(OrionTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func accentDot(_ accent: OrionAccent) -> some View {
        let selected = appearance.customAccentHex.isEmpty && appearance.accentID == accent.id
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: accent.hex), Color(hex: accent.deepHex)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Color(hex: accent.hex).orionContrastingText)
                }
            }
            .overlay(
                Circle().stroke(OrionTheme.textPrimary.opacity(selected ? 0.9 : 0),
                                lineWidth: 2)
                    .padding(-3)
            )

            Text(accent.title)
                .font(.caption2)
                .foregroundColor(selected ? OrionTheme.textPrimary : OrionTheme.textTertiary)
        }
    }

    /// ColorPicker отдаёт Color — храним его как hex, чтобы оформление
    /// переживало перезапуск и было доступно виджету.
    private var customAccentBinding: Binding<Color> {
        Binding(
            get: { appearance.accentColor },
            set: { appearance.customAccentHex = $0.orionHexString }
        )
    }

    // MARK: - Фон

    private var backdropSection: some View {
        section("Фон", hint: backdropHint) {
            VStack(spacing: 14) {
                chipRow(OrionBackdrop.allCases,
                        current: appearance.backdrop,
                        title: { $0.title }) { value in
                    if value == .wallpaper && appearance.wallpaper == nil { return }
                    apply { appearance.backdrop = value }
                }

                HStack(spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(appearance.wallpaper == nil ? "Выбрать обои" : "Заменить обои",
                              systemImage: "photo.on.rectangle.angled")
                            .font(.caption.weight(.medium))
                            .foregroundColor(OrionTheme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .glassPill(tint: OrionTheme.accent)
                    }

                    if appearance.wallpaper != nil {
                        Button {
                            apply { appearance.setWallpaper(nil) }
                        } label: {
                            Label("Убрать", systemImage: "trash")
                                .font(.caption.weight(.medium))
                                .foregroundColor(OrionTheme.danger)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .glassPill()
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }

                if appearance.backdrop == .wallpaper {
                    slider("Затемнение", value: $appearance.wallpaperDim,
                           range: 0.15...0.9,
                           caption: "\(Int(appearance.wallpaperDim * 100))%")
                    slider("Размытие", value: $appearance.wallpaperBlur,
                           range: 0...30,
                           caption: "\(Int(appearance.wallpaperBlur)) pt")
                }
            }
        }
    }

    private var backdropHint: String {
        appearance.wallpaper == nil
            ? "«Сияние» — медленно дышащие пятна акцента за стеклом. Для варианта «Обои» сначала выбери картинку."
            : "Обои лежат в контейнере приложения и никуда не отправляются. Затемнение и размытие нужны, чтобы текст поверх остался читаемым."
    }

    // MARK: - Стекло и форма

    private var glassSection: some View {
        section("Жидкое стекло",
                hint: "Материал с настоящим размытием фона, бликом и световой кромкой — так карточки выглядят объёмными. «Выкл» делает поверхности плотными: чуть быстрее и контрастнее.") {
            chipRow(OrionGlassLevel.allCases,
                    current: appearance.glass,
                    title: { $0.title }) { value in
                apply { appearance.glass = value }
            }
        }
    }

    private var shapeSection: some View {
        section("Углы") {
            chipRow(OrionCornerStyle.allCases,
                    current: appearance.corners,
                    title: { $0.title }) { value in
                apply { appearance.corners = value }
            }
        }
    }

    // MARK: - Текст

    private var typeSection: some View {
        section("Размер текста", hint: "Работает во всём приложении. Системный размер из «Настроек» iPhone при этом никуда не девается — этот множитель поверх него.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(0..<OrionAppearance.dynamicSizes.count, id: \.self) { index in
                        chip(OrionAppearance.dynamicSizes[index].title,
                             selected: appearance.textSizeIndex == index) {
                            apply { appearance.textSizeIndex = index }
                        }
                    }
                }

                Text("Пример: «Обстановка спокойная, 12 %»")
                    .font(.subheadline)
                    .foregroundColor(OrionTheme.textSecondary)
                    .dynamicTypeSize(appearance.dynamicTypeSize)
            }
        }
    }

    // MARK: - Движение

    private var motionSection: some View {
        section("Движение", hint: "Системное «Уменьшение движения» всегда сильнее этих тумблеров: если оно включено в iOS, анимаций не будет независимо от настроек здесь.") {
            VStack(spacing: 10) {
                Toggle("Анимации", isOn: $appearance.animationsEnabled)
                    .tint(OrionTheme.accent)
                    .foregroundColor(OrionTheme.textPrimary)

                Toggle("Живое сияние фона", isOn: $appearance.ambientMotion)
                    .tint(OrionTheme.accent)
                    .foregroundColor(OrionTheme.textPrimary)
                    .disabled(!appearance.animationsEnabled)
                    .opacity(appearance.animationsEnabled ? 1 : 0.45)
            }
        }
    }

    // MARK: - Питомец

    private var petSection: some View {
        section("Питомец", hint: "Украшение интерфейса: ходит по экрану, играет с точкой на карте, дремлет калачиком у кнопки SOS. Ничего не измеряет и никуда не передаёт данные.") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Питомец в приложении", isOn: $appearance.petsEnabled)
                    .tint(OrionTheme.accent)
                    .foregroundColor(OrionTheme.textPrimary)

                if appearance.petsEnabled {
                    petSpeciesPicker
                    petFurPicker

                    HStack {
                        Text("Имя")
                            .font(.subheadline)
                            .foregroundColor(OrionTheme.textSecondary)
                        TextField(companion.species.defaultName, text: $appearance.petName)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(OrionTheme.textPrimary)
                    }

                    Toggle("Играет с точкой на карте", isOn: $appearance.petOnMap)
                        .tint(OrionTheme.accent)
                        .foregroundColor(OrionTheme.textPrimary)

                    Toggle("Дремлет у кнопки SOS", isOn: $appearance.petGuardsSOS)
                        .tint(OrionTheme.accent)
                        .foregroundColor(OrionTheme.textPrimary)

                    petMoodRow
                }
            }
        }
    }

    private var petSpeciesPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(PetSpecies.allCases) { species in
                    Button {
                        apply { appearance.petSpeciesID = species.rawValue }
                    } label: {
                        speciesCard(species)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
    }

    private func speciesCard(_ species: PetSpecies) -> some View {
        let selected = appearance.petSpeciesID == species.rawValue
        let shape = RoundedRectangle(cornerRadius: OrionTheme.Radius.chip, style: .continuous)
        // Карточка показывает вид уже в выбранном для него окрасе — иначе
        // человек выбирает вслепую и удивляется цвету после переключения.
        let hex = appearance.petFurHex(for: species)
        return VStack(spacing: 4) {
            PetPreview(species: species, size: 54,
                       tint: hex == species.defaultFurHex ? nil : Color(hex: hex))
            Text(species.title)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(selected ? OrionTheme.accent : OrionTheme.textTertiary)
                .frame(width: 62)
        }
        .padding(8)
        .background(shape.fill(OrionTheme.surface.opacity(selected ? 0.5 : 0.2)))
        .overlay(shape.stroke(selected ? OrionTheme.accent : OrionTheme.border,
                              lineWidth: selected ? 1.5 : 1))
    }

    /// Окрас шерсти. Только естественные цвета вида: акцент интерфейса сюда
    /// намеренно не заведён — синий кот выглядит не как питомец, а как сбой.
    private var petFurPicker: some View {
        let species = companion.species
        let current = appearance.petFurHex(for: species)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Окрас")
                .font(.subheadline)
                .foregroundColor(OrionTheme.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(species.furOptions) { fur in
                        Button {
                            apply { appearance.setPetFur(fur.hex, for: species) }
                        } label: {
                            furChip(fur, selected: fur.hex == current)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(fur.title)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
        }
    }

    private func furChip(_ fur: PetFur, selected: Bool) -> some View {
        VStack(spacing: 4) {
            Circle()
                .fill(Color(hex: fur.hex))
                .frame(width: 34, height: 34)
                .overlay(
                    Circle().stroke(selected ? OrionTheme.accent : OrionTheme.border,
                                    lineWidth: selected ? 2.5 : 1)
                )
            Text(fur.title)
                .font(.caption2)
                .foregroundColor(selected ? OrionTheme.accent : OrionTheme.textTertiary)
        }
    }

    /// Настроение и привязанность — то немногое, что у питомца есть
    /// «внутри». Гладить можно прямо отсюда.
    private var petMoodRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(companion.displayName) — \(companion.mood.title)")
                    .font(.caption.weight(.medium))
                    .foregroundColor(OrionTheme.textPrimary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(OrionTheme.surfaceHi)
                        Capsule().fill(OrionTheme.accentGradient)
                            .frame(width: max(4, geo.size.width * CGFloat(companion.affection)))
                    }
                }
                .frame(height: 6)
                Text("привязанность \(Int(companion.affection * 100))%")
                    .font(.caption2)
                    .foregroundColor(OrionTheme.textTertiary)
            }

            Button {
                companion.pet()
            } label: {
                Label("Погладить", systemImage: "hand.point.up.left.fill")
                    .font(.caption.weight(.medium))
                    .foregroundColor(OrionTheme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .glassPill(tint: OrionTheme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Сброс

    private var resetSection: some View {
        Button(role: .destructive) {
            showReset = true
        } label: {
            Label("Сбросить оформление", systemImage: "arrow.counterclockwise")
                .font(.subheadline.weight(.medium))
                .foregroundColor(OrionTheme.danger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .liquidGlass(cornerRadius: OrionTheme.Radius.button, shadow: false)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Кирпичики

    /// Обёртка секции: заголовок капсом, содержимое, мелкая подпись.
    private func section<Content: View>(_ title: String,
                                        hint: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).orionSectionLabel()
            content()
            if let hint = hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundColor(OrionTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundColor(selected ? OrionTheme.accent.orionContrastingText : OrionTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background {
                    let shape = RoundedRectangle(cornerRadius: OrionTheme.Radius.chip, style: .continuous)
                    if selected {
                        shape.fill(OrionTheme.accentGradient)
                    } else {
                        LiquidGlass(shape: shape, strength: 0.7)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: OrionTheme.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func chipRow<T: Identifiable & Equatable>(_ items: [T],
                                                      current: T,
                                                      title: @escaping (T) -> String,
                                                      select: @escaping (T) -> Void) -> some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                chip(title(item), selected: item == current) { select(item) }
            }
        }
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(OrionTheme.textSecondary)
                Spacer()
                Text(caption)
                    .font(.caption2.monospaced())
                    .foregroundColor(OrionTheme.textTertiary)
            }
            Slider(value: value, in: range)
                .tint(OrionTheme.accent)
        }
    }

    // MARK: - Мелочи

    /// Любое изменение оформления — с общей анимацией (и без неё,
    /// если анимации выключены или включено «Уменьшение движения»).
    private func apply(_ change: () -> Void) {
        withAnimation(appearance.animation(.easeInOut(duration: 0.22))) {
            change()
        }
    }

    private func loadWallpaper(from item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                appearance.setWallpaper(image)
                photoItem = nil
            }
        }
    }
}
