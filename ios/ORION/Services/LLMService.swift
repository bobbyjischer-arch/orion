import Foundation

/// Контекст, отправляемый «мозгу» на анализ.
/// Зеркалит SuspicionContext из orion_final/core/llm.py.
struct SuspicionContext {
    let latitude: Double
    let longitude: Double
    var localTime: String = ""       // "HH:mm" локального времени
    var speedMps: Double? = nil
    var placeType: String = ""       // грубый тип местности
    var nearPOI: String = ""         // имя ближайшей точки интереса
    var routeDeviation: String = ""  // отклонение от привычных мест
    // Из памяти AEGIS (AegisMemory в SuspicionService.swift). nil — памяти
    // нечего сказать; тогда движок рассуждает ровно как раньше, без этих сигналов.
    var dwellMinutes: Double? = nil  // сколько минут стоит в одной ячейке
    var placeKnown: Bool? = nil      // привычное ли это место

    var promptText: String {
        var lines = [
            String(format: "Координаты: %.5f, %.5f", latitude, longitude),
            "Локальное время: \(localTime.isEmpty ? "неизвестно" : localTime)",
        ]
        if let s = speedMps {
            lines.append(String(format: "Скорость: %.1f м/с", s))
        }
        if !placeType.isEmpty { lines.append("Тип местности: \(placeType)") }
        if !nearPOI.isEmpty { lines.append("Рядом точка интереса: \(nearPOI)") }
        if !routeDeviation.isEmpty { lines.append("Отклонение от привычных мест: \(routeDeviation)") }
        if let d = dwellMinutes, d >= 1 { lines.append("Стоит на одном месте: \(Int(d)) мин") }
        if let known = placeKnown { lines.append("Место: " + (known ? "привычное" : "незнакомое")) }
        return lines.joined(separator: "\n")
    }
}

/// Контекст для мед-анализа состояния. Зеркалит HealthContext в llm.py.
struct HealthContext {
    var steps: Int = 0
    var distanceMeters: Double = 0
    var weightKg: Double? = nil
    var weightTrendKg: Double? = nil
    var mood: Int? = nil          // 1..5
    var stress: Int? = nil        // 1..5
    var sleepHours: Double? = nil
    var supplements: [String] = []
    var note: String = ""
    // Валидированные скринеры: по два ответа 0..3 (PHQ-2 — интерес и
    // настроение, GAD-2 — нервозность и беспокойство). nil — не проходили.
    var phq2: [Int]? = nil
    var gad2: [Int]? = nil
    // Ряды журнала для трендов: ["mood": [...], "sleep_hours": [...]],
    // значения от старых к новым. Хватает четырёх точек.
    var series: [String: [Double]] = [:]

    var promptText: String {
        var lines = ["Шаги сегодня: \(steps)"]
        if distanceMeters > 0 { lines.append(String(format: "Дистанция: %.1f км", distanceMeters / 1000)) }
        if let w = weightKg { lines.append(String(format: "Вес: %.1f кг", w)) }
        if let t = weightTrendKg { lines.append(String(format: "Тренд веса за месяц: %+.1f кг", t)) }
        if let m = mood { lines.append("Настроение: \(m)/5") }
        if let s = stress { lines.append("Стресс: \(s)/5") }
        if let sl = sleepHours { lines.append(String(format: "Сон: %.1f ч", sl)) }
        if !supplements.isEmpty { lines.append("БАДы/приём: " + supplements.joined(separator: ", ")) }
        if !note.isEmpty { lines.append("Заметка: \(note)") }
        // Скринеры отдаём уже посчитанными: сумму и вердикт считает AEGIS,
        // нейросети остаётся только учесть их в тексте.
        let screens = MentalScreen.all(self)
        for key in screens.keys.sorted() {
            guard let s = screens[key] else { continue }
            lines.append("\(key.uppercased()): \(s.score)/\(s.maxScore) — "
                         + (s.positive ? "положительный" : "отрицательный"))
        }
        return lines.joined(separator: "\n")
    }
}

/// Результат валидированного двухвопросного скринера (порт screen_mental
/// из server/core/aegis.py). Не диагноз: положительный результат означает
/// ровно одно — есть повод пройти полную шкалу (PHQ-9 / GAD-7) со специалистом.
struct MentalScreen: Codable, Equatable {
    let score: Int          // 0..6
    let maxScore: Int
    let cutoff: Int
    let positive: Bool
    let label: String

    enum CodingKeys: String, CodingKey {
        case score, cutoff, positive, label
        case maxScore = "max"
    }

    /// Общепринятая точка отсечения обоих скринеров.
    static let screenCutoff = 3

    /// Скринер спрашивает про последние две недели — старше он не о сегодняшнем
    /// состоянии, и тянуть его в анализ нельзя.
    static let validDays: Double = 14

    // Формулировки пунктов — те же, что в server/core/aegis.py.
    static let phq2Questions = [
        "Мало интереса или удовольствия от дел",
        "Подавленность, тоска или безнадёжность",
    ]
    static let gad2Questions = [
        "Нервозность, тревога или взвинченность",
        "Не получалось перестать волноваться",
    ]
    /// Шкала ответа: как часто это беспокоило за две недели.
    static let answerLabels = ["совсем нет", "несколько дней",
                               "больше половины дней", "почти каждый день"]

    static func all(_ ctx: HealthContext) -> [String: MentalScreen] {
        var out: [String: MentalScreen] = [:]
        if let phq2 = sum(ctx.phq2) {
            out["phq2"] = MentalScreen(score: phq2, maxScore: 6, cutoff: screenCutoff,
                                       positive: phq2 >= screenCutoff,
                                       label: "депрессивные симптомы")
        }
        if let gad2 = sum(ctx.gad2) {
            out["gad2"] = MentalScreen(score: gad2, maxScore: 6, cutoff: screenCutoff,
                                       positive: gad2 >= screenCutoff,
                                       label: "тревожные симптомы")
        }
        return out
    }

    /// Сумма 0..6. nil — опрос не проходили или он заполнен наполовину:
    /// по половине ответов скринер не считают.
    private static func sum(_ answers: [Int]?) -> Int? {
        guard let a = answers, a.count >= 2 else { return nil }
        return a.prefix(2).reduce(0) { $0 + max(0, min(3, $1)) }
    }
}

/// Куда движется показатель журнала (порт analyze_trends из server/core/aegis.py).
struct HealthTrend: Codable, Equatable {
    let slope: Double
    let label: String
    let direction: String     // «хуже» | «лучше» | «ровно»
    let worsening: Bool

    /// На трёх точках «тренд» — это шум.
    static let minPoints = 4

    /// Что считаем ухудшением: ключ ряда → порог наклона, «выше — лучше?», подпись.
    private static let rules: [(key: String, threshold: Double, higherIsBetter: Bool, label: String)] = [
        ("mood",        -0.15,  true,  "настроение"),
        ("sleep_hours", -0.20,  true,  "сон"),
        ("steps",       -300.0, true,  "активность"),
        ("stress",       0.15,  false, "стресс"),
    ]

    static func all(_ series: [String: [Double]]) -> [String: HealthTrend] {
        var out: [String: HealthTrend] = [:]
        for rule in rules {
            guard let s = slope(series[rule.key] ?? []) else { continue }
            let worsening = rule.higherIsBetter ? s <= rule.threshold : s >= rule.threshold
            let improving = rule.higherIsBetter ? s >= -rule.threshold : s <= -rule.threshold
            out[rule.key] = HealthTrend(
                slope: (s * 1000).rounded() / 1000,
                label: rule.label,
                direction: worsening ? "хуже" : (improving ? "лучше" : "ровно"),
                worsening: worsening
            )
        }
        return out
    }

    /// Наклон методом наименьших квадратов по индексу. nil — точек мало.
    private static func slope(_ values: [Double]) -> Double? {
        let n = values.count
        guard n >= minPoints else { return nil }
        let meanX = Double(n - 1) / 2
        let meanY = values.reduce(0, +) / Double(n)
        let denom = (0..<n).reduce(0.0) { $0 + pow(Double($1) - meanX, 2) }
        guard denom != 0 else { return nil }
        let num = values.enumerated().reduce(0.0) {
            $0 + (Double($1.offset) - meanX) * ($1.element - meanY)
        }
        return num / denom
    }
}

/// Вердикт мед-анализа. Зеркалит HealthAssessment в llm.py.
struct HealthAssessment: Codable, Equatable {
    let score: Int            // 0..100 общее самочувствие (выше — лучше)
    let summary: String
    let recommendations: [String]
    var source: String = "llm"
    // Считает всегда AEGIS: скринеры и тренды — арифметика по журналу,
    // доверять её нейросети незачем, а показать человеку нужно в любом случае.
    var screens: [String: MentalScreen] = [:]
    var trends: [String: HealthTrend] = [:]

    enum CodingKeys: String, CodingKey {
        case score, summary, recommendations, source, screens, trends
    }

    init(score: Int, summary: String, recommendations: [String], source: String = "llm",
         screens: [String: MentalScreen] = [:], trends: [String: HealthTrend] = [:]) {
        self.score = score
        self.summary = summary
        self.recommendations = recommendations
        self.source = source
        self.screens = screens
        self.trends = trends
    }

    /// Декодирование терпимо к отсутствию полей: нейросеть шлёт только
    /// score/summary/recommendations (без source, скринеров и трендов).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = try c.decode(Int.self, forKey: .score)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        recommendations = try c.decodeIfPresent([String].self, forKey: .recommendations) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "llm"
        screens = try c.decodeIfPresent([String: MentalScreen].self, forKey: .screens) ?? [:]
        trends = try c.decodeIfPresent([String: HealthTrend].self, forKey: .trends) ?? [:]
    }

    /// Автономный мед-анализ AEGIS (порт assess_health из server/core/aegis.py).
    /// Не диагноз и не замена врача — ориентир по простым порогам. Работает всегда.
    static func aegis(_ ctx: HealthContext) -> HealthAssessment {
        var score = 75
        var flags: [String] = []
        var recs: [String] = []

        if ctx.steps < 2000 {
            score -= 12
            flags.append("мало активности")
            recs.append("Постарайся пройтись хотя бы 20–30 минут.")
        } else if ctx.steps >= 8000 {
            score += 5
        }

        if let sleep = ctx.sleepHours {
            if sleep < 6 {
                score -= 15
                flags.append("недосып")
                recs.append("Сон меньше 6 часов бьёт по вниманию и настроению — добери отдых.")
            } else if sleep > 9 {
                score -= 5
                flags.append("пересып")
            }
        }

        // Скринеры считаем до разовых отметок: PHQ-2 спрашивает ровно про то же,
        // что галочка «настроение», а GAD-2 — про то же, что «стресс». Если
        // валидированный опрос заполнен, судим по нему и разовую отметку не
        // штрафуем: иначе один признак наказывался бы дважды и шкала упиралась в 0.
        let screens = MentalScreen.all(ctx)

        if screens["phq2"] == nil, let mood = ctx.mood, mood <= 2 {
            score -= 15
            flags.append("сниженное настроение")
            recs.append("Настроение низкое несколько дней подряд — стоит поговорить с близким или специалистом.")
        }

        if screens["gad2"] == nil, let stress = ctx.stress, stress >= 4 {
            score -= 15
            flags.append("высокий стресс")
            recs.append("Высокий стресс: короткая прогулка и дыхательная пауза помогут снять пик.")
        }

        if let trend = ctx.weightTrendKg, abs(trend) >= 3 {
            score -= 8
            flags.append("резкое изменение веса (\(trend < 0 ? "снижение" : "рост"))")
            recs.append("Резкое изменение веса за месяц — если не намеренно, покажись врачу.")
        }

        // Скринеры весят больше разового «плохого дня»: они спрашивают про
        // устойчивую картину за две недели, а не про сегодняшнее настроение.
        for key in screens.keys.sorted() {
            guard let s = screens[key], s.positive else { continue }
            score -= 20
            flags.append("\(s.label) по \(key.uppercased()) (\(s.score)/\(s.maxScore))")
        }
        if screens["phq2"]?.positive == true {
            recs.append("PHQ-2 положительный — это не диагноз, но повод пройти полную шкалу "
                        + "с врачом или психологом.")
        }
        if screens["gad2"]?.positive == true {
            recs.append("GAD-2 положительный — тревога держится не первый день; "
                        + "стоит обсудить это со специалистом.")
        }

        // Тренды: одна плохая точка — случайность, устойчивое сползание — сигнал.
        let trends = HealthTrend.all(ctx.series)
        let worsening = trends.values.filter { $0.worsening }.map { $0.label }.sorted()
        if !worsening.isEmpty {
            score -= 5 * worsening.count
            flags.append("ухудшается: " + worsening.joined(separator: ", "))
            recs.append("Показатели сползают несколько дней подряд — "
                        + "посмотри, что изменилось в режиме.")
        }

        score = max(0, min(100, score))

        let summary: String
        if flags.isEmpty {
            summary = "AEGIS: по данным всё в норме, тревожных признаков не вижу."
            if recs.isEmpty { recs = ["Так держать — продолжай в том же ритме."] }
        } else {
            summary = "AEGIS: обратил внимание на — " + flags.joined(separator: ", ") + "."
        }

        return HealthAssessment(
            score: score,
            summary: summary,
            recommendations: Array(recs.prefix(4)),
            source: "aegis",
            screens: screens,
            trends: trends
        )
    }
}

/// Внешний слой «мозга». Базовый вердикт ВСЕГДА даёт автономный AEGIS
/// (SuspicionAssessment.aegis); нейросеть — необязательное второе мнение
/// (source "aegis+llm"). Ключ берётся из Keychain. Системный промпт
/// совпадает с llm.py, чтобы «мозг» думал одинаково в приложении и в боте.
final class LLMService {

    static let endpoint = "https://openrouter.ai/api/v1/chat/completions"
    // Список бесплатных моделей OpenRouter ротируется. Этот id рабочий на
    // момент сборки; если перестанет — поменяй модель в Настройках.
    static let defaultModel = "deepseek/deepseek-chat-v3-0324:free"

    /// Причина последнего сбоя обращения к LLM (для показа в UI).
    /// nil — последний вызов прошёл успешно.
    private(set) var lastError: String?

    /// Активный endpoint: из настроек, либо дефолтный OpenRouter.
    /// Если введён только хост (без /chat/completions) — дописываем путь,
    /// чтобы запрос уходил на корректный OpenAI-совместимый адрес.
    static var activeEndpoint: String {
        var v = AppSettings.shared.llmEndpoint.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return endpoint }
        while v.hasSuffix("/") { v.removeLast() }
        if !v.contains("/chat/completions") {
            v += v.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions"
        }
        return v
    }

    private static let systemPrompt = """
    Ты — O.R.I.O.N., система мониторинга безопасности пользователя. \
    По контексту его местоположения оцени, насколько вероятно, что ему \
    нужна помощь, по шкале подозрения 0..100.
    Ориентиры:
    - день, людное/безопасное место (набережная, парк, кафе) → 0..20
    - обычное перемещение по городу → 10..35
    - ночь в нетипичном месте, низкая скорость долго → 40..70
    - глубокая ночь (2..5) в промзоне/пустыре/на отшибе → 75..100
    Если подозрение высокое (>=60) — следует задать пользователю мягкий \
    уточняющий вопрос, всё ли с ним хорошо.
    Отвечай СТРОГО одним JSON-объектом без markdown и пояснений, поля:
    {"suspicion": <int 0..100>, "reason": "<кратко по-русски>", \
    "should_ask": <true|false>, "question": "<вопрос пользователю или пустая строка>"}
    """

    private static let healthSystemPrompt = """
    Ты — O.R.I.O.N., ассистент по благополучию. По данным о состоянии \
    пользователя (активность, вес, сон, настроение, стресс, БАДы) дай \
    краткую оценку общего самочувствия по шкале 0..100 (выше — лучше) и \
    практичные рекомендации. Ты НЕ ставишь диагнозов и не заменяешь врача; \
    при тревожных признаках советуй обратиться к специалисту.
    Отвечай СТРОГО одним JSON-объектом без markdown, поля:
    {"score": <int 0..100>, "summary": "<2-3 предложения по-русски>", \
    "recommendations": ["<совет>", "<совет>"]}
    """

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Оценить уровень подозрения. Никогда не бросает: базовый вердикт всегда
    /// даёт автономный AEGIS; нейросеть — необязательное второе мнение.
    func analyze(_ ctx: SuspicionContext, model: String? = nil) async -> SuspicionAssessment {
        let key = (try? KeychainService.shared.retrieve(for: .openRouterKey)) ?? ""
        let base = Self.aegisBase(ctx)

        guard !key.isEmpty else {
            lastError = nil   // штатный автономный режим, не ошибка
            return base
        }

        guard let url = URL(string: Self.activeEndpoint) else {
            lastError = "Неверный endpoint"
            return base
        }

        let usedModel = model?.isEmpty == false ? model! : Self.defaultModel
        let body: [String: Any] = [
            "model": usedModel,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": ctx.promptText],
            ],
            "temperature": 0.3,
            "max_tokens": 700,   // запас под «думающие» модели (Gemini 2.5, и т.п.)
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("O.R.I.O.N.", forHTTPHeaderField: "X-Title")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                lastError = Self.httpErrorMessage(code: code, data: data, model: usedModel)
                return base
            }
            guard let content = Self.extractContent(data) else {
                lastError = "Пустой ответ модели"
                return base
            }
            guard let nn = Self.parse(content) else {
                lastError = "Не удалось разобрать ответ модели"
                return base
            }
            lastError = nil
            return Self.merge(nn: nn, aegis: base)
        } catch {
            lastError = "Сеть: \(error.localizedDescription)"
            return base
        }
    }

    /// Мед-анализ состояния. Никогда не бросает: без ключа или при сбое
    /// отвечает автономный AEGIS.
    func analyzeHealth(_ ctx: HealthContext, model: String? = nil) async -> HealthAssessment {
        let key = (try? KeychainService.shared.retrieve(for: .openRouterKey)) ?? ""
        guard !key.isEmpty else {
            lastError = nil   // штатный автономный режим, не ошибка
            return .aegis(ctx)
        }
        guard let url = URL(string: Self.activeEndpoint) else {
            lastError = "Неверный endpoint"
            return .aegis(ctx)
        }

        let usedModel = model?.isEmpty == false ? model! : Self.defaultModel
        let body: [String: Any] = [
            "model": usedModel,
            "messages": [
                ["role": "system", "content": Self.healthSystemPrompt],
                ["role": "user", "content": ctx.promptText],
            ],
            "temperature": 0.4,
            "max_tokens": 900,   // запас под «думающие» модели
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("O.R.I.O.N.", forHTTPHeaderField: "X-Title")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                lastError = Self.httpErrorMessage(code: code, data: data, model: usedModel)
                return .aegis(ctx)
            }
            guard let content = Self.extractContent(data) else {
                lastError = "Пустой ответ модели"
                return .aegis(ctx)
            }
            guard var parsed = Self.parseHealth(content) else {
                lastError = "Не удалось разобрать ответ модели"
                return .aegis(ctx)
            }
            lastError = nil
            // Скринеры и тренды приживляем от AEGIS: нейросеть про них не
            // спрашивали, а терять их из-за того, что ответила модель, нельзя.
            let base = HealthAssessment.aegis(ctx)
            parsed.screens = base.screens
            parsed.trends = base.trends
            return parsed
        } catch {
            lastError = "Сеть: \(error.localizedDescription)"
            return .aegis(ctx)
        }
    }

    /// Человекочитаемое сообщение об ошибке HTTP от OpenRouter.
    private static func httpErrorMessage(code: Int, data: Data, model: String) -> String {
        var detail = ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let msg = err["message"] as? String {
            detail = " — \(msg)"
        } else if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
            detail = " — \(raw.prefix(180))"   // сырой ответ, если формат нестандартный
        }
        switch code {
        case 300..<400:
            return "Перенаправление (\(code)) — проверь endpoint (должен оканчиваться на /v1/chat/completions)\(detail)"
        case 400: return "Запрос отклонён (400). Обычно неверный id модели для этого шлюза (для Gemini: gemini-2.5-flash, не claude/anthropic).\(detail)"
        case 401: return "Ключ неверный или не принят шлюзом (401)\(detail)"
        case 402: return "Закончился лимит/нужен баланс (402)\(detail)"
        case 404: return "Модель «\(model)» или endpoint недоступны (404). Проверь id модели и адрес.\(detail)"
        case 429: return "Превышен лимит запросов (429), попробуй позже\(detail)"
        default:  return "Ошибка ИИ-шлюза (\(code))\(detail)"
        }
    }

    // MARK: - Private helpers

    private static func parseHealth(_ content: String) -> HealthAssessment? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
            text = text.replacingOccurrences(of: "```", with: "")
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(HealthAssessment.self, from: data) else {
            return nil
        }
        return HealthAssessment(
            score: max(0, min(100, parsed.score)),
            summary: parsed.summary.isEmpty ? "—" : parsed.summary,
            recommendations: parsed.recommendations,
            source: "llm"
        )
    }

    /// Базовый вердикт автономного мозга AEGIS по контексту.
    private static func aegisBase(_ ctx: SuspicionContext) -> SuspicionAssessment {
        SuspicionAssessment.aegis(
            hour: hour(from: ctx.localTime),
            placeType: ctx.placeType,
            routeDeviation: ctx.routeDeviation,
            speedMps: ctx.speedMps,
            dwellMinutes: ctx.dwellMinutes,
            placeKnown: ctx.placeKnown
        )
    }

    /// Подмешивает вердикт нейросети как второе мнение к AEGIS.
    /// Итог — максимум осторожности: не занижаем оценку ниже автономной.
    private static func merge(nn: SuspicionAssessment, aegis base: SuspicionAssessment) -> SuspicionAssessment {
        let merged = max(nn.suspicion, base.suspicion)
        // Причина — от того, чей suspicion выше; голос/действие — всегда от AEGIS.
        let reason = (nn.suspicion > base.suspicion && !nn.reason.isEmpty) ? nn.reason : base.reason
        let ask = nn.shouldAsk || merged >= 60
        return SuspicionAssessment(
            suspicion: merged,
            reason: reason,
            shouldAsk: ask,
            question: ask ? (nn.question.isEmpty ? base.question : nn.question) : "",
            source: "aegis+llm",
            voice: base.voice,
            action: base.action,
            confidence: base.confidence
        )
    }

    private static func extractContent(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return nil }
        return content
    }

    /// Парсит JSON-вердикт нейросети (в т.ч. обёрнутый в ```); nil при мусоре.
    private static func parse(_ content: String) -> SuspicionAssessment? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
            text = text.replacingOccurrences(of: "```", with: "")
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SuspicionAssessment.self, from: data) else {
            return nil
        }
        // На случай, если модель прислала source — принудительно "llm".
        return SuspicionAssessment(
            suspicion: max(0, min(100, parsed.suspicion)),
            reason: parsed.reason,
            shouldAsk: parsed.shouldAsk,
            question: parsed.question,
            source: "llm"
        )
    }

    private static func hour(from localTime: String) -> Int? {
        Int(localTime.split(separator: ":").first.map(String.init) ?? "")
    }
}
