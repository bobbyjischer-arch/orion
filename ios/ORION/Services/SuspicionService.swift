import Foundation
import CoreLocation

/// Срез памяти AEGIS — то, что «мозг» знает о прошлом, когда судит о настоящем.
struct AegisMemorySnapshot {
    var level: Int = 20
    var dwellMinutes: Double = 0
    /// true — привычное место, false — незнакомое, nil — сказать пока нечего.
    var placeKnown: Bool? = nil
    var habitualPlaces: Int = 0
    var knownPlaces: Int = 0
}

/// Память обстановки (порт server/core/aegis_memory.py).
///
/// Чего не хватало AEGIS v1: `aegis(hour:placeType:...)` — чистая функция, она
/// видит один срез и ничего не помнит. Человек, только что пришедший на
/// пустырь, и человек, стоящий там сорок минут, выглядели одинаково.
///
/// Память закрывает три дыры: затухание уровня по РЕАЛЬНОМУ времени (а не «за
/// вызов»), привычные места (ячейки ~110 м) и dwell — сколько минут человек
/// фактически стоит на одном месте. Веса и пороги те же, что на сервере.
struct AegisMemory: Codable {

    static let baseline: Double = 20
    static let halfLifeMin: Double = 45
    static let rise: Double = 0.6
    static let cellPrecision: Double = 1000      // 3 знака после запятой ≈ 110 м
    static let habitualVisits = 3
    static let habitualDays = 2
    static let maxPlaces = 200
    static let stillSpeedMps: Double = 0.5
    static let dwellGapMin: Double = 30

    /// Одна запомненная ячейка карты.
    struct Place: Codable {
        var cell: String
        var visits: Int = 0
        var days: [String] = []       // ISO-даты визитов, без повторов
        var minutes: Double = 0
        var lastSeen: Date? = nil

        var habitual: Bool {
            visits >= AegisMemory.habitualVisits && days.count >= AegisMemory.habitualDays
        }
    }

    var level: Double = AegisMemory.baseline
    var lastUpdate: Date? = nil
    var places: [String: Place] = [:]
    var dwellCell: String? = nil
    var dwellMinutes: Double = 0

    // MARK: - Ячейки

    /// Квантовать координату в ячейку сетки. nil, если координат нет.
    static func cell(lat: Double?, lon: Double?) -> String? {
        guard let lat, let lon, lat.isFinite, lon.isFinite else { return nil }
        return String(format: "%.3f,%.3f", lat, lon)
    }

    // MARK: - Затухание

    /// Уровень, притянутый к покою за прошедшее время. Ничего не меняет.
    private func decayed(at now: Date) -> Double {
        guard let prev = lastUpdate else { return level }
        let minutes = max(0, now.timeIntervalSince(prev) / 60)
        return Self.baseline + (level - Self.baseline) * pow(0.5, minutes / Self.halfLifeMin)
    }

    /// Каким уровень стал бы к моменту `now`, если наблюдений так и не было.
    /// Отдельно от `observe`, потому что читающей стороне (UI) нельзя двигать
    /// lastUpdate: иначе следующее наблюдение увидело бы нулевой разрыв и
    /// dwell перестал бы накапливаться от одного лишь показа экрана.
    func level(at now: Date = Date()) -> Int {
        Self.clamp(decayed(at: now))
    }

    // MARK: - Наблюдение

    /// Учесть одно наблюдение и вернуть срез памяти.
    /// `instant` — мгновенная оценка обстановки; память отвечает только за
    /// накопление, места и dwell, своего мнения об обстановке у неё нет.
    @discardableResult
    mutating func observe(instant: Int, lat: Double?, lon: Double?,
                          speedMps: Double? = nil, now: Date = Date()) -> AegisMemorySnapshot {
        let gapMin = lastUpdate.map { max(0, now.timeIntervalSince($0) / 60) } ?? 0

        // 1. Сначала затухание за прошедшее время, потом подъём к instant.
        //    Порядок важен: иначе свежий всплеск сразу же «съедался» бы спадом.
        level = decayed(at: now)
        if Double(instant) > level {
            level += Self.rise * (Double(instant) - level)
        }

        let cell = Self.cell(lat: lat, lon: lon)
        let moved = cell != nil && cell != dwellCell
        let still = speedMps == nil || speedMps! < Self.stillSpeedMps

        // 2. Dwell: копим минуты, пока ячейка та же и человек не разогнался.
        //    Долгий разрыв обнуляет счёт — что было в паузе, память не знает
        //    и додумывать не станет.
        if cell == nil || moved || !still || gapMin > Self.dwellGapMin {
            dwellCell = cell
            dwellMinutes = 0
        } else {
            dwellMinutes += gapMin
        }

        // 3. Места: визит засчитываем при заходе в ячейку, а не на каждый тик.
        if let cell {
            var place = places[cell] ?? Place(cell: cell)
            if moved || place.visits == 0 { place.visits += 1 }
            let day = Self.dayFormatter.string(from: now)
            if !place.days.contains(day) { place.days.append(day) }
            place.minutes += min(gapMin, Self.dwellGapMin)
            place.lastSeen = now
            places[cell] = place
            evict()
        }

        lastUpdate = now
        return snapshot(lat: lat, lon: lon)
    }

    // MARK: - Срез для рассуждения

    func snapshot(lat: Double? = nil, lon: Double? = nil, now: Date? = nil) -> AegisMemorySnapshot {
        let cell = Self.cell(lat: lat, lon: lon) ?? dwellCell
        var known: Bool? = nil
        if let cell {
            // nil означает «нечего сказать»: место видим впервые и статистики по
            // нему нет. «Незнакомое» говорим только когда память уже накопила
            // хоть какую-то картину привычных мест — иначе в первый день
            // работы приложения весь мир был бы незнакомым.
            if places[cell]?.habitual == true {
                known = true
            } else if habitualCount > 0 {
                known = false
            }
        }
        return AegisMemorySnapshot(
            level: now.map { level(at: $0) } ?? Self.clamp(level),
            dwellMinutes: (dwellMinutes * 10).rounded() / 10,
            placeKnown: known,
            habitualPlaces: habitualCount,
            knownPlaces: places.count
        )
    }

    var habitualCount: Int { places.values.filter { $0.habitual }.count }

    // MARK: - Внутреннее

    /// Вытеснить самые давно не виденные ячейки, привычные — в последнюю очередь.
    private mutating func evict() {
        guard places.count > Self.maxPlaces else { return }
        let ordered = places.values.sorted {
            if $0.habitual != $1.habitual { return !$0.habitual }
            return ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast)
        }
        for place in ordered.prefix(places.count - Self.maxPlaces) {
            places.removeValue(forKey: place.cell)
        }
    }

    private static func clamp(_ v: Double, _ lo: Int = 0, _ hi: Int = 100) -> Int {
        max(lo, min(hi, Int(v.rounded())))
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Хранилище памяти AEGIS в App Group: «мозг» должен помнить привычные места
/// между запусками, иначе после каждого перезапуска дом снова незнакомый.
enum AegisMemoryStore {
    private static let key = "aegis_memory_v1"

    static func load() -> AegisMemory {
        let d = UserDefaults(suiteName: AppSettings.appGroup) ?? .standard
        guard let data = d.data(forKey: key),
              let mem = try? JSONDecoder().decode(AegisMemory.self, from: data) else {
            return AegisMemory()
        }
        return mem
    }

    static func save(_ memory: AegisMemory) {
        let d = UserDefaults(suiteName: AppSettings.appGroup) ?? .standard
        guard let data = try? JSONEncoder().encode(memory) else { return }
        d.set(data, forKey: key)
    }
}

/// «Счётчик подозрений» — связывает поток геолокации с «мозгом» (LLM)
/// и публикует текущий вердикт для UI.
///
/// Вызывается из LocationService после успешной отправки точки, с
/// троттлингом, чтобы не дёргать LLM на каждое обновление координат.
@MainActor
final class SuspicionService: ObservableObject {

    static let shared = SuspicionService()

    @Published var assessment: SuspicionAssessment?
    @Published var isAnalyzing = false
    @Published var lastAnalyzed: Date?
    /// Режим «Анализирую» сразу после старта слежения (для UI/озвучки).
    @Published var startupAnalyzing = false
    /// Причина последнего сбоя LLM (для показа в UI), nil если успех.
    @Published var lastError: String?

    /// Минимальный интервал между обращениями к LLM.
    var minInterval: TimeInterval = 600   // 10 минут

    private let llm = LLMService()
    private let notif = NotificationService.shared
    private let geocoder = CLGeocoder()

    /// Память AEGIS: переживает перезапуск, копится неделями.
    private var memory = AegisMemoryStore.load()

    private init() {}

    /// Срез памяти для UI и отладки. Читает, ничего не сдвигая: показ экрана
    /// не должен обнулять разрыв между наблюдениями, иначе dwell перестанет
    /// накапливаться от одного лишь взгляда на статус.
    var memorySnapshot: AegisMemorySnapshot { memory.snapshot(now: Date()) }

    /// Наблюдение для памяти: без сети, без геокодинга — вызывать на каждую
    /// точку. Поток координат и есть единственный регулярный пульс; если учить
    /// память только в `evaluate` (раз в 10 минут), dwell будет считаться по
    /// редким разрозненным замерам и не будет значить ничего.
    ///
    /// Мгновенную оценку считаем тем же скорером, что и накопитель: у памяти
    /// не должно быть собственного мнения об обстановке.
    @discardableResult
    func observe(location: CLLocation, speed: Double?,
                 placeType: String = "", routeDeviation: String = "") -> AegisMemorySnapshot {
        // Выключен «мозг» — не копим и историю мест: это тоже персональные
        // данные, и тумблер должен выключать наблюдение целиком, а не только
        // обращения к нейросети.
        guard AppSettings.shared.suspicionEnabled else { return memory.snapshot(now: Date()) }
        let mps = speed.map { max(0, $0) }
        let instant = SuspicionAssessment.instantScore(
            hour: Calendar.current.component(.hour, from: Date()),
            placeType: placeType,
            routeDeviation: routeDeviation,
            speedMps: mps
        )
        let snapshot = memory.observe(instant: instant,
                                      lat: location.coordinate.latitude,
                                      lon: location.coordinate.longitude,
                                      speedMps: mps)
        AegisMemoryStore.save(memory)
        return snapshot
    }

    /// Старт слежения: режим «Анализирую» — озвучка + немедленный
    /// первый анализ маршрута (сбрасываем троттлинг).
    func begin() {
        guard AppSettings.shared.suspicionEnabled else { return }
        startupAnalyzing = true
        lastAnalyzed = nil
        SpeechService.shared.speak("Анализирую")
    }

    /// Главная точка входа. Безопасно вызывать часто — внутри троттлинг.
    func evaluate(location: CLLocation, speed: Double?, history: [LocationPoint] = []) async {
        guard AppSettings.shared.suspicionEnabled else { return }

        if let last = lastAnalyzed, Date().timeIntervalSince(last) < minInterval {
            return
        }
        guard !isAnalyzing else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        lastAnalyzed = Date()

        let placeType = await reverseGeocodePlaceType(location)
        var ctx = SuspicionContext(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        ctx.localTime = Self.localTimeString()
        ctx.speedMps = speed.map { max(0, $0) }
        ctx.placeType = placeType
        if let poi = PointsOfInterestService.shared.nearest(to: location) {
            ctx.nearPOI = "\(poi.name) (\(poi.category.rawValue))"
        }
        ctx.routeDeviation = Self.deviationHint(location: location, history: history)

        // Память кормим полным контекстом (тип места и отклонение уже известны)
        // и её же срез отдаём движку: dwell и «привычное место» — это ВХОД для
        // рассуждения, а не его вывод.
        let snapshot = observe(location: location, speed: speed,
                               placeType: placeType, routeDeviation: ctx.routeDeviation)
        ctx.dwellMinutes = snapshot.dwellMinutes
        ctx.placeKnown = snapshot.placeKnown

        let result = await llm.analyze(ctx, model: AppSettings.shared.openRouterModel)
        assessment = result
        lastError = llm.lastError
        startupAnalyzing = false

        if result.suspicion >= 60 {
            let q = result.question.isEmpty ? "Всё ли с тобой хорошо?" : result.question
            notif.notifySuspicion(level: result.suspicion, question: q)
        }
    }

    /// Сброс после ответа пользователя «всё ок».
    func acknowledge() {
        guard let a = assessment else { return }
        assessment = SuspicionAssessment(
            suspicion: 0,
            reason: "Подтверждено пользователем",
            shouldAsk: false,
            question: "",
            source: a.source
        )
    }

    // MARK: - Context helpers

    private static func localTimeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    /// Грубая оценка отклонения от центроида истории маршрутов.
    /// Зеркалит _route_deviation_hint в core/main.py.
    private static func deviationHint(location: CLLocation, history: [LocationPoint]) -> String {
        guard history.count >= 10 else { return "" }
        let pts = history.suffix(200)
        let clat = pts.map { $0.latitude }.reduce(0, +) / Double(pts.count)
        let clon = pts.map { $0.longitude }.reduce(0, +) / Double(pts.count)
        let centroid = CLLocation(latitude: clat, longitude: clon)
        let km = location.distance(from: centroid) / 1000
        if km > 15 { return String(format: "далеко (%.0f км)", km) }
        if km > 5  { return String(format: "умеренно (%.0f км)", km) }
        return String(format: "в пределах привычной зоны (%.1f км)", km)
    }

    /// Грубо определяет тип местности по обратному геокодингу.
    /// Возвращает короткий ярлык вроде "набережная", "промзона", "жильё".
    private func reverseGeocodePlaceType(_ location: CLLocation) async -> String {
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return ""
        }
        // areasOfInterest / thoroughfare дают грубую подсказку о характере места.
        let hints = [
            placemark.areasOfInterest?.joined(separator: " "),
            placemark.thoroughfare,
            placemark.subLocality,
        ].compactMap { $0 }.joined(separator: " ").lowercased()

        if hints.contains("набережн") || hints.contains("embankment") { return "набережная" }
        if hints.contains("парк") || hints.contains("park") { return "парк" }
        if hints.contains("промз") || hints.contains("industrial") { return "промзона" }
        return placemark.subLocality ?? placemark.thoroughfare ?? ""
    }
}
