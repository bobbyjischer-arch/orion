import SwiftUI

/// Фальшивое хранилище файлов.
/// Показывается при неверном пароле.
/// Выглядит как настоящее приложение — фотографии, документы, заметки.
/// Скрытый вход в ORION: набрать свой код доступа в строке поиска.
///
/// Оформление — системное (`.secondary`, `systemGroupedBackground`) плюс
/// фиксированные hex-цвета, а не токены OrionTheme: подделка должна выглядеть
/// как обычное приложение из App Store. Если бы она подхватывала палитру
/// владельца, совпадение цветов выдало бы связь с ORION.
struct DecoyVaultView: View {

    let onCorrectCode: () -> Void

    @State private var selectedTab  = 0
    @State private var searchText   = ""

    /// Длина кода — та же, что на экране блокировки: проверяем только
    /// когда набрано ровно столько цифр, чтобы не дёргать Keychain на
    /// каждую букву обычного поиска.
    private let codeLength = 4

    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()

                TabView(selection: $selectedTab) {
                    filesTab
                        .tabItem { Label("Файлы", systemImage: "folder.fill") }
                        .tag(0)

                    photosTab
                        .tabItem { Label("Фото", systemImage: "photo.fill") }
                        .tag(1)

                    docsTab
                        .tabItem { Label("Документы", systemImage: "doc.fill") }
                        .tag(2)

                    settingsDecoyTab
                        .tabItem { Label("Настройки", systemImage: "gearshape.fill") }
                        .tag(3)
                }
                .accentColor(Color(hex: "4FC3F7"))
            }
        }
        .onChange(of: searchText) { text in
            // Скрытый триггер — свой код доступа (или код тревоги: тогда
            // AppLock.attempt заодно отправит тихий SOS) в строке поиска.
            guard text.count == codeLength,
                  text.allSatisfy(\.isNumber),
                  AppLock.shared.attempt(text) else { return }
            // Без задержки: attempt уже снял блокировку, и лишняя пауза
            // оставила бы вызов onCorrectCode на уже убранном экране.
            searchText = ""
            onCorrectCode()
        }
    }

    // MARK: - Вкладка: Файлы

    var filesTab: some View {
        List {
            Section("Недавние") {
                ForEach(DecoyData.recentFiles) { f in
                    NavigationLink {
                        DecoyFileDetailView(name: f.name, size: f.size, date: f.date)
                    } label: {
                        DecoyFileRow(file: f)
                    }
                }
            }
            Section("Папки") {
                ForEach(DecoyData.folders) { folder in
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .foregroundColor(Color(hex: "4FC3F7"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.name).font(.body)
                            Text("\(folder.count) файлов")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Secure Vault")
        .searchable(text: $searchText, prompt: "Поиск файлов")
        .navigationBarItems(
            trailing: Button {
                // поиск активируется через поле поиска
            } label: {
                Image(systemName: "plus")
            }
        )
    }

    // MARK: - Вкладка: Фото

    var photosTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Защищённые фото")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 8)

                // Сетка заглушек. ВАЖНО: значения стабильны между рендерами —
                // раньше здесь были Double.random/randomElement прямо в body,
                // и плитки мерцали при каждой перерисовке (выдавало подделку).
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 2) {
                    ForEach(DecoyData.photoTiles) { tile in
                        Rectangle()
                            .fill(Color.gray.opacity(tile.opacity))
                            .aspectRatio(1, contentMode: .fill)
                            .overlay(
                                Image(systemName: tile.icon)
                                    .foregroundColor(.gray.opacity(0.3))
                            )
                    }
                }

                Text("\(DecoyData.photoTiles.count) объектов · \(DecoyData.photoSizeMB) МБ")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
        }
        .navigationTitle("Фото")
    }

    // MARK: - Вкладка: Документы

    var docsTab: some View {
        List {
            Section("Последние") {
                ForEach(DecoyData.documents) { doc in
                    NavigationLink {
                        DecoyFileDetailView(name: doc.name, size: doc.size, date: doc.date)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: doc.icon)
                                .font(.title2)
                                .foregroundColor(doc.color)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.name).font(.body)
                                Text(doc.date + " · " + doc.size)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Документы")
    }

    // MARK: - Вкладка: Настройки (decoy)

    var settingsDecoyTab: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(hex: "4FC3F7"))
                            .frame(width: 44, height: 44)
                        Image(systemName: "person.fill")
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Мой аккаунт")
                            .font(.headline)
                        Text("Локальное хранилище")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Хранилище") {
                decoySettingsRow("iCloud Sync", icon: "cloud.fill",   color: "4FC3F7", value: "Вкл")
                decoySettingsRow("Биометрия",   icon: "faceid",        color: "30D158", value: "Face ID")
                decoySettingsRow("Занято",       icon: "internaldrive", color: "FF9F0A", value: "1.2 ГБ")
            }
            Section("Безопасность") {
                decoySettingsRow("Автоблокировка", icon: "lock.fill",      color: "FF453A", value: "1 мин")
                decoySettingsRow("Фейковый пароль",icon: "key.fill",       color: "BF5AF2", value: "••••")
                decoySettingsRow("Журнал входов",  icon: "list.bullet",    color: "636366", value: "")
            }
            Section {
                Button(role: .destructive) { } label: {
                    HStack {
                        Spacer()
                        Text("Сбросить данные")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Настройки")
    }

    func decoySettingsRow(_ title: String, icon: String, color: String, value: String) -> some View {
        HStack {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: color))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.white)
            }
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.subheadline)
        }
    }
}

// MARK: - Просмотрщик фейкового файла

/// Экран-заглушка «открытого» файла. Показывает правдоподобное
/// содержимое по типу файла, усиливая иллюзию рабочего приложения.
struct DecoyFileDetailView: View {
    let name: String
    let size: String
    let date: String

    private var kind: Kind {
        let n = name.lowercased()
        if n.hasSuffix(".txt") || n.contains("парол") || n.contains("замет") { return .text }
        if n.hasSuffix(".jpg") || n.hasSuffix(".png") || n.contains("фото") || n.contains("паспорт") { return .image }
        if n.hasSuffix(".xlsx") || n.contains("смета") || n.contains("реквизит") { return .table }
        if n.hasSuffix(".pdf") || n.hasSuffix(".doc") || n.contains("договор") || n.contains("резюме") || n.contains("страхов") { return .document }
        if n.hasSuffix(".zip") || n.contains("копи") || n.contains("скан") { return .archive }
        return .generic
    }

    enum Kind { case text, image, table, document, archive, generic }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch kind {
                case .text:     textBody
                case .image:    imageBody
                case .table:    tableBody
                case .document: documentBody
                case .archive:  archiveBody
                case .generic:  genericBody
                }
            }
            .padding()
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Виды содержимого

    private var textBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(DecoyContent.notes, id: \.self) { line in
                Text(line).font(.system(.body, design: .monospaced))
            }
        }
    }

    private var imageBody: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.2))
                    .frame(height: 280)
                Image(systemName: "photo")
                    .font(.system(size: 64)).foregroundColor(.gray.opacity(0.4))
            }
            metaRow("Разрешение", "4032 × 3024")
            metaRow("Камера", "12 МП, f/1.8")
            metaRow("Размер", size)
            metaRow("Дата", date)
        }
    }

    private var tableBody: some View {
        VStack(spacing: 0) {
            ForEach(Array(DecoyContent.tableRows.enumerated()), id: \.offset) { idx, row in
                HStack {
                    Text(row.0).frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.1).frame(width: 110, alignment: .trailing)
                        .foregroundColor(.secondary)
                }
                .font(.system(.callout, design: .monospaced))
                .padding(.vertical, 8)
                .background(idx % 2 == 0 ? Color.gray.opacity(0.08) : Color.clear)
            }
        }
        .cornerRadius(8)
    }

    private var documentBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name.replacingOccurrences(of: ".pdf", with: "").replacingOccurrences(of: ".doc", with: ""))
                .font(.title3.bold())
            ForEach(DecoyContent.paragraphs, id: \.self) { p in
                Text(p).font(.body).foregroundColor(.primary.opacity(0.85))
            }
        }
    }

    private var archiveBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Архив · \(size)", systemImage: "doc.zipper").font(.headline)
            Divider()
            ForEach(DecoyContent.archiveEntries, id: \.self) { e in
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill").foregroundColor(.gray).font(.caption)
                    Text(e).font(.system(.callout, design: .monospaced))
                }
            }
        }
    }

    private var genericBody: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.fill").font(.system(size: 56)).foregroundColor(.gray.opacity(0.4))
            Text("Предпросмотр недоступен").foregroundColor(.secondary)
            metaRow("Размер", size)
            metaRow("Дата", date)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func metaRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundColor(.secondary)
            Spacer()
            Text(v).font(.system(.callout, design: .monospaced))
        }
    }
}

/// Правдоподобные заглушки содержимого.
enum DecoyContent {
    static let notes = [
        "— записать показания счётчиков",
        "— продлить страховку до конца месяца",
        "— wifi гостевой: Guest_2024 / 8845xx",
        "— перезвонить по объявлению",
        "— купить подарок на ДР",
    ]
    static let paragraphs = [
        "Настоящий документ составлен в двух экземплярах, имеющих одинаковую юридическую силу, по одному для каждой из сторон.",
        "Стороны пришли к соглашению о нижеследующем: предмет, сроки и порядок исполнения обязательств определяются согласно приложению.",
        "Все споры и разногласия решаются путём переговоров. В случае недостижения согласия спор передаётся на рассмотрение в установленном порядке.",
    ]
    static let tableRows: [(String, String)] = [
        ("Материалы", "42 300 ₽"),
        ("Работы", "65 000 ₽"),
        ("Доставка", "3 500 ₽"),
        ("Непредвиденное", "10 000 ₽"),
        ("Итого", "120 800 ₽"),
    ]
    static let archiveEntries = [
        "scan_001.jpg", "scan_002.jpg", "scan_003.pdf", "опись.txt",
    ]
}

// MARK: - Decoy Data Models

struct DecoyFile: Identifiable {
    let id    = UUID()
    let name:  String
    let icon:  String
    let color: String
    let size:  String
    let date:  String
}

struct DecoyFolder: Identifiable {
    let id    = UUID()
    let name:  String
    let count: Int
}

struct DecoyDocument: Identifiable {
    let id    = UUID()
    let name:  String
    let icon:  String
    let color: Color
    let date:  String
    let size:  String
}

/// Стабильная плитка фейкового «фото» (без рандома в рантайме).
struct DecoyPhotoTile: Identifiable {
    let id: Int
    let icon: String
    let opacity: Double
}

struct DecoyData {
    /// Предвычисленные плитки фото — детерминированы, не мерцают.
    static let photoTiles: [DecoyPhotoTile] = {
        let icons = ["photo", "photo.fill", "camera.fill", "video.fill"]
        // Детерминированный «псевдослучай» из индекса, чтобы выглядело
        // разнообразно, но было одинаковым при каждом показе.
        return (0..<18).map { i in
            DecoyPhotoTile(
                id: i,
                icon: icons[(i * 7 + 3) % icons.count],
                opacity: 0.10 + Double((i * 37) % 16) / 100.0   // 0.10…0.25
            )
        }
    }()

    /// Стабильный «размер библиотеки».
    static let photoSizeMB = "487.5"

    static let recentFiles: [DecoyFile] = [
        .init(name: "Сканы документов.zip",  icon: "doc.zipper",        color: "FF9F0A", size: "24.3 МБ", date: "Сегодня"),
        .init(name: "Резюме_2024.pdf",        icon: "doc.fill",          color: "FF453A", size: "1.8 МБ",  date: "Вчера"),
        .init(name: "Пароли.txt",             icon: "doc.text.fill",     color: "636366", size: "4 КБ",    date: "3 дня назад"),
        .init(name: "Фото паспорта.jpg",      icon: "photo.fill",        color: "30D158", size: "3.2 МБ",  date: "5 дней назад"),
        .init(name: "Банковские реквизиты",   icon: "creditcard.fill",   color: "4FC3F7", size: "12 КБ",   date: "Неделю назад"),
    ]

    static let folders: [DecoyFolder] = [
        .init(name: "Документы",       count: 23),
        .init(name: "Фотографии",      count: 147),
        .init(name: "Важное",          count: 8),
        .init(name: "Резервные копии", count: 3),
        .init(name: "Разное",          count: 41),
    ]

    static let documents: [DecoyDocument] = [
        .init(name: "Договор аренды.pdf",  icon: "doc.fill",       color: .red,    date: "12.03.2025", size: "2.1 МБ"),
        .init(name: "Смета_ремонт.xlsx",   icon: "tablecells.fill", color: .green,  date: "28.02.2025", size: "340 КБ"),
        .init(name: "Заметки.txt",         icon: "note.text",       color: .orange, date: "15.01.2025", size: "8 КБ"),
        .init(name: "Страховка ОСАГО.pdf", icon: "doc.fill",        color: .red,    date: "01.01.2025", size: "1.5 МБ"),
    ]
}

// MARK: - Decoy File Row

struct DecoyFileRow: View {
    let file: DecoyFile
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.icon)
                .font(.title2)
                .foregroundColor(Color(hex: file.color))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.body).lineLimit(1)
                Text(file.date + " · " + file.size)
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "ellipsis")
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}
