import Foundation
import CoreMotion
import Combine

/// Сбор базовых данных о состоянии: шагомер (CoreMotion), вес, тесты
/// ментального состояния, список БАДов, свободные заметки. Всё хранится
/// локально в App Group и является журналом записей: правки и удаления
/// не теряются (soft-delete), поэтому историю можно смотреть и
/// восстанавливать. Эти данные используются анализом состояния
/// (`LLMService.analyzeHealth`).
@MainActor
final class HealthService: ObservableObject {

    static let shared = HealthService()

    @Published var todaySteps: Int = 0
    @Published var todayDistance: Double = 0          // метры
    @Published var weights: [WeightEntry] = []
    @Published var moods: [MoodEntry] = []
    @Published var supplements: [Supplement] = []
    @Published var notes: [NoteEntry] = []
    @Published var pedometerAvailable = false

    private let pedometer = CMPedometer()

    private init() {
        loadAll()
        pedometerAvailable = CMPedometer.isStepCountingAvailable()
    }

    // MARK: - Живые (неудалённые) записи для UI

    var activeWeights: [WeightEntry]     { weights.filter { !$0.deleted } }
    var activeMoods: [MoodEntry]         { moods.filter { !$0.deleted } }
    var activeSupplements: [Supplement]  { supplements.filter { !$0.deleted } }
    var activeNotes: [NoteEntry]         { notes.filter { !$0.deleted } }

    /// Вся история одним списком (свежие сверху), включая удалённые —
    /// экран истории показывает факт удаления, а не прячет его.
    func history(includeDeleted: Bool = false) -> [SyncRecord] {
        var all = weights.map(\.syncRecord)
            + moods.map(\.syncRecord)
            + supplements.map(\.syncRecord)
            + notes.map(\.syncRecord)
        if !includeDeleted { all = all.filter { !$0.deleted } }
        return all.sorted { $0.createdAt > $1.createdAt }
    }

    /// Записи, изменённые позже указанного момента — дельта для синка.
    func recordsChanged(since: Date?) -> [SyncRecord] {
        let all = weights.map(\.syncRecord)
            + moods.map(\.syncRecord)
            + supplements.map(\.syncRecord)
            + notes.map(\.syncRecord)
        guard let since else { return all }
        return all.filter { $0.updatedAt > since }
    }

    // MARK: - Шагомер

    func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        let startOfDay = Calendar.current.startOfDay(for: Date())

        // Накопленные шаги за сегодня
        pedometer.queryPedometerData(from: startOfDay, to: Date()) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor in
                self?.todaySteps = data.numberOfSteps.intValue
                self?.todayDistance = data.distance?.doubleValue ?? 0
            }
        }

        // Live-обновления
        pedometer.startUpdates(from: startOfDay) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor in
                self?.todaySteps = data.numberOfSteps.intValue
                self?.todayDistance = data.distance?.doubleValue ?? 0
            }
        }
    }

    func stopPedometer() {
        pedometer.stopUpdates()
    }

    // MARK: - Вес

    func addWeight(_ kg: Double, date: Date = Date()) {
        weights.append(WeightEntry(date: date, kg: kg))
        weights.sort { $0.date < $1.date }
        persistWeights()
    }

    func updateWeight(_ entry: WeightEntry, kg: Double, date: Date? = nil) {
        guard let i = weights.firstIndex(where: { $0.id == entry.id }) else { return }
        weights[i].kg = kg
        if let date { weights[i].date = date }
        weights[i].updatedAt = Date()
        weights.sort { $0.date < $1.date }
        persistWeights()
    }

    func deleteWeight(_ entry: WeightEntry) {
        guard let i = weights.firstIndex(where: { $0.id == entry.id }) else { return }
        weights[i].deleted = true
        weights[i].updatedAt = Date()
        persistWeights()
    }

    var latestWeight: WeightEntry? { activeWeights.last }

    /// Изменение веса за последние ~30 дней (кг), если есть данные.
    var weightTrend: Double? {
        let live = activeWeights
        guard let last = live.last else { return nil }
        let monthAgo = Date().addingTimeInterval(-30 * 86400)
        guard let baseline = live.first(where: { $0.date >= monthAgo }) ?? live.first,
              baseline.id != last.id else { return nil }
        return last.kg - baseline.kg
    }

    // MARK: - Настроение / ментальный тест

    func addMood(_ entry: MoodEntry) {
        moods.append(entry)
        moods.sort { $0.date < $1.date }
        persistMoods()
    }

    func updateMood(_ entry: MoodEntry, mood: Int, stress: Int,
                    sleepHours: Double, note: String) {
        guard let i = moods.firstIndex(where: { $0.id == entry.id }) else { return }
        moods[i].mood = mood
        moods[i].stress = stress
        moods[i].sleepHours = sleepHours
        moods[i].note = note
        moods[i].updatedAt = Date()
        persistMoods()
    }

    func deleteMood(_ entry: MoodEntry) {
        guard let i = moods.firstIndex(where: { $0.id == entry.id }) else { return }
        moods[i].deleted = true
        moods[i].updatedAt = Date()
        persistMoods()
    }

    var latestMood: MoodEntry? { activeMoods.last }

    // MARK: - БАДы / добавки

    func addSupplement(_ s: Supplement) {
        supplements.append(s)
        persistSupplements()
    }

    func updateSupplement(_ s: Supplement, name: String, dose: String, schedule: String) {
        guard let i = supplements.firstIndex(where: { $0.id == s.id }) else { return }
        supplements[i].name = name
        supplements[i].dose = dose
        supplements[i].schedule = schedule
        supplements[i].updatedAt = Date()
        persistSupplements()
    }

    func deleteSupplement(_ s: Supplement) {
        guard let i = supplements.firstIndex(where: { $0.id == s.id }) else { return }
        supplements[i].deleted = true
        supplements[i].updatedAt = Date()
        persistSupplements()
    }

    // MARK: - Свободные заметки

    func addNote(title: String, text: String, date: Date = Date()) {
        notes.append(NoteEntry(date: date, title: title, text: text))
        notes.sort { $0.date < $1.date }
        persistNotes()
    }

    func updateNote(_ entry: NoteEntry, title: String, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == entry.id }) else { return }
        notes[i].title = title
        notes[i].text = text
        notes[i].updatedAt = Date()
        persistNotes()
    }

    func deleteNote(_ entry: NoteEntry) {
        guard let i = notes.firstIndex(where: { $0.id == entry.id }) else { return }
        notes[i].deleted = true
        notes[i].updatedAt = Date()
        persistNotes()
    }

    // MARK: - Правка/удаление по записи истории

    /// Удалить запись, найденную в истории (по её строковому id).
    /// Возвращает false, если запись не нашлась.
    @discardableResult
    func deleteRecord(_ record: SyncRecord) -> Bool {
        switch record.kind {
        case .weight:
            guard let e = weights.first(where: { $0.id.uuidString == record.id }) else { return false }
            deleteWeight(e)
        case .mood:
            guard let e = moods.first(where: { $0.id.uuidString == record.id }) else { return false }
            deleteMood(e)
        case .supplement:
            guard let e = supplements.first(where: { $0.id.uuidString == record.id }) else { return false }
            deleteSupplement(e)
        case .note:
            guard let e = notes.first(where: { $0.id.uuidString == record.id }) else { return false }
            deleteNote(e)
        }
        return true
    }

    /// Восстановить ранее удалённую запись (снимает soft-delete).
    @discardableResult
    func restoreRecord(_ record: SyncRecord) -> Bool {
        let now = Date()
        switch record.kind {
        case .weight:
            guard let i = weights.firstIndex(where: { $0.id.uuidString == record.id }) else { return false }
            weights[i].deleted = false; weights[i].updatedAt = now; persistWeights()
        case .mood:
            guard let i = moods.firstIndex(where: { $0.id.uuidString == record.id }) else { return false }
            moods[i].deleted = false; moods[i].updatedAt = now; persistMoods()
        case .supplement:
            guard let i = supplements.firstIndex(where: { $0.id.uuidString == record.id }) else { return false }
            supplements[i].deleted = false; supplements[i].updatedAt = now; persistSupplements()
        case .note:
            guard let i = notes.firstIndex(where: { $0.id.uuidString == record.id }) else { return false }
            notes[i].deleted = false; notes[i].updatedAt = now; persistNotes()
        }
        return true
    }

    // MARK: - Контекст для мед-ИИ

    func makeHealthContext() -> HealthContext {
        // Ряды журнала для трендов: от старых к новым (moods уже отсортированы
        // по дате). Больше двух недель назад — это уже другой период жизни.
        let recent = activeMoods.suffix(14)
        var series: [String: [Double]] = [:]
        if !recent.isEmpty {
            series["mood"] = recent.map { Double($0.mood) }
            series["stress"] = recent.map { Double($0.stress) }
            series["sleep_hours"] = recent.map { $0.sleepHours }
        }
        return HealthContext(
            steps: todaySteps,
            distanceMeters: todayDistance,
            weightKg: latestWeight?.kg,
            weightTrendKg: weightTrend,
            mood: latestMood?.mood,
            stress: latestMood?.stress,
            sleepHours: latestMood?.sleepHours,
            supplements: activeSupplements.map {
                [$0.name, $0.dose, $0.schedule].filter { !$0.isEmpty }.joined(separator: " ")
            },
            note: latestMood?.note ?? "",
            phq2: latestScreener(\.phq2),
            gad2: latestScreener(\.gad2),
            series: series
        )
    }

    /// Последний пройденный скринер, если он ещё актуален. Скринеры
    /// заполняют не каждый день, поэтому берём свежайший из журнала,
    /// а не из последней записи.
    private func latestScreener(_ path: KeyPath<MoodEntry, [Int]?>) -> [Int]? {
        let deadline = Date().addingTimeInterval(-MentalScreen.validDays * 86400)
        let entry = activeMoods.last(where: { $0.date >= deadline && $0[keyPath: path] != nil })
        return entry?[keyPath: path] ?? nil
    }

    // MARK: - Persistence (App Group)

    private func fileURL(_ name: String) -> URL? {
        AppSettings.sharedFileURL(name)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard let url = fileURL(name), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url)
    }

    private func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let url = fileURL(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persistWeights()     { save(weights, "health_weights.json") }
    private func persistMoods()       { save(moods, "health_moods.json") }
    private func persistSupplements() { save(supplements, "health_supplements.json") }
    private func persistNotes()       { save(notes, "health_notes.json") }

    private func loadAll() {
        weights = load("health_weights.json", as: [WeightEntry].self) ?? []
        moods = load("health_moods.json", as: [MoodEntry].self) ?? []
        supplements = load("health_supplements.json", as: [Supplement].self) ?? []
        notes = load("health_notes.json", as: [NoteEntry].self) ?? []
    }
}
