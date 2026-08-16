import Foundation

/// Вердикт «мозга» O.R.I.O.N. — насколько вероятно, что пользователю
/// нужна помощь. Контракт совпадает с серверной версией
/// (server/core/llm.py → SuspicionAssessment).
struct SuspicionAssessment: Codable, Equatable {
    /// Уровень подозрения 0..100.
    let suspicion: Int
    /// Короткое объяснение по-русски.
    let reason: String
    /// Нужно ли задать пользователю уточняющий вопрос.
    let shouldAsk: Bool
    /// Текст вопроса (пустая строка, если shouldAsk == false).
    let question: String
    /// Источник вердикта: "aegis" | "aegis+llm" | "llm".
    var source: String = "llm"
    /// Реплика «голосом» ассистента (от AEGIS).
    var voice: String = ""
    /// Рекомендованное действие: monitor | ask | prepare_sos.
    var action: String = "monitor"
    /// Уверенность AEGIS в выводе 0..100.
    var confidence: Int = 0
    /// Уверенность словами («высокая», «предварительная»…) — v3.
    /// Опционально: старые сохранённые вердикты декодируются без него.
    var confidenceWord: String? = nil

    enum CodingKeys: String, CodingKey {
        case suspicion
        case reason
        case shouldAsk = "should_ask"
        case question
        case source
        case voice
        case action
        case confidence
        case confidenceWord = "confidence_word"
    }

    init(suspicion: Int, reason: String, shouldAsk: Bool, question: String,
         source: String = "llm", voice: String = "",
         action: String = "monitor", confidence: Int = 0,
         confidenceWord: String? = nil) {
        self.suspicion = suspicion
        self.reason = reason
        self.shouldAsk = shouldAsk
        self.question = question
        self.source = source
        self.voice = voice
        self.action = action
        self.confidence = confidence
        self.confidenceWord = confidenceWord
    }

    /// Декодирование терпимо к отсутствию полей: нейросеть шлёт только
    /// suspicion/reason/should_ask/question, остальное добавляет AEGIS.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        suspicion = try c.decode(Int.self, forKey: .suspicion)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        shouldAsk = try c.decodeIfPresent(Bool.self, forKey: .shouldAsk) ?? (suspicion >= 60)
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "llm"
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? "monitor"
        confidence = try c.decodeIfPresent(Int.self, forKey: .confidence) ?? 0
        confidenceWord = try c.decodeIfPresent(String.self, forKey: .confidenceWord)
    }

    /// Категория для UI (цвет/иконка).
    enum Level {
        case calm       // 0..39
        case watch      // 40..59
        case alarm      // 60..100
    }

    var level: Level {
        switch suspicion {
        case ..<40:  return .calm
        case 40..<60: return .watch
        default:      return .alarm
        }
    }

    // ══════════════════════════════════════════════════════════════
    //  A.E.G.I.S. — автономный мозг (порт server/core/aegis.py).
    //  Работает всегда: без ключа, без сети, без нейросети.
    //  Веса сигналов зеркалят server/core/suspicion.py.
    // ══════════════════════════════════════════════════════════════

    static let aegisCallsign = "AEGIS"
    /// Порог опроса пользователя (ASK_THRESHOLD в suspicion.py).
    private static let askThreshold = 60

    /// Один распознанный фактор с вкладом (aegis.Signal).
    private struct Signal {
        let code: String
        let label: String
        let weight: Int
    }

    /// Классификация местности → вклад в подозрение (_ZONE_WEIGHTS).
    private static let zoneWeights: [(key: String, weight: Int)] = [
        ("промзон", 35), ("пустыр", 35), ("склад", 25), ("стройк", 25),
        ("гараж", 20), ("отшиб", 30), ("лес", 20), ("трасс", 10),
        ("набережн", -15), ("парк", -15), ("кафе", -10), ("тц", -10),
        ("центр", -5), ("дом", -20), ("работ", -15),
    ]

    private static func clamp(_ v: Int, _ lo: Int = 0, _ hi: Int = 100) -> Int {
        max(lo, min(hi, v))
    }

    private static func hourScore(_ hour: Int?) -> Int {
        guard let h = hour else { return 0 }
        if h >= 2 && h < 5 { return 35 }                       // глубокая ночь
        if h >= 23 || h < 2 { return 25 }
        if (h >= 5 && h < 7) || (h >= 21 && h < 23) { return 10 }
        return 0                                               // день
    }

    private static func zoneScore(_ placeType: String) -> Int {
        let p = placeType.lowercased()
        var score = 0
        for (key, w) in zoneWeights where p.contains(key) {
            score += w
        }
        return score
    }

    private static func deviationScore(_ routeDeviation: String) -> Int {
        let d = routeDeviation.lowercased()
        if d.contains("далеко") { return 25 }
        if d.contains("умеренно") { return 10 }
        return 0
    }

    private static func speedScore(_ speedMps: Double?, hour: Int?) -> Int {
        guard let s = speedMps else { return 0 }
        let night = hour.map { $0 >= 22 || $0 < 6 } ?? false
        if s < 0.3 && night { return 15 }    // долго стоит ночью
        if s > 2.5 { return -5 }             // уверенно движется
        return 0
    }

    /// Мгновенная оценка теми же скорерами, что и накопитель, без рассуждений
    /// о сочетаниях (порт instant_suspicion из server/core/suspicion.py).
    /// Ею кормится память: у неё не должно быть своего мнения об обстановке.
    static func instantScore(hour: Int?, placeType: String = "",
                             routeDeviation: String = "", speedMps: Double? = nil) -> Int {
        clamp(20 + hourScore(hour) + zoneScore(placeType)
              + deviationScore(routeDeviation) + speedScore(speedMps, hour: hour))
    }

    /// Разложить обстановку на именованные факторы (_collect_signals).
    ///
    /// `dwellMinutes` / `placeKnown` приходят из памяти (AegisMemory); nil —
    /// памяти нечего сказать, и движок ведёт себя ровно как v1.
    private static func collectSignals(hour: Int?, placeType: String,
                                       routeDeviation: String, speedMps: Double?,
                                       dwellMinutes: Double?, placeKnown: Bool?) -> [Signal] {
        var signals: [Signal] = []

        let hs = hourScore(hour)
        if hs >= 25 {
            signals.append(Signal(code: "night", label: "глубокая ночь", weight: hs))
        } else if hs > 0 {
            signals.append(Signal(code: "dusk", label: "вечер / раннее утро", weight: hs))
        }

        let zs = zoneScore(placeType)
        if zs >= 20 {
            signals.append(Signal(code: "industrial", label: "нежилая / промзона", weight: zs))
        } else if zs > 0 {
            signals.append(Signal(code: "odd_place", label: "нетипичное место", weight: zs))
        } else if zs < 0 {
            signals.append(Signal(code: "safe_place", label: "безопасное место", weight: zs))
        }

        let ds = deviationScore(routeDeviation)
        if ds >= 25 {
            signals.append(Signal(code: "far_deviation", label: "далеко от привычных мест", weight: ds))
        } else if ds > 0 {
            signals.append(Signal(code: "mild_deviation", label: "лёгкое отклонение маршрута", weight: ds))
        }

        let ss = speedScore(speedMps, hour: hour)
        if ss > 0 {
            signals.append(Signal(code: "motionless", label: "подозрительно неподвижен", weight: ss))
        } else if ss < 0 {
            signals.append(Signal(code: "moving", label: "уверенно движется", weight: ss))
        }

        // v3: слишком быстро для пешего — ночью в промзоне это отдельный сюжет.
        if let mps = speedMps, mps >= 3.5, mps < 14 {
            signals.append(Signal(code: "rushing", label: "движение бегом", weight: 8))
        }

        // Память: сколько человек уже стоит на одном месте. Мгновенная
        // неподвижность (motionless) и сорок минут в одной точке — разные вещи.
        if let dwell = dwellMinutes {
            if dwell >= 45 {
                signals.append(Signal(code: "long_dwell", label: "не двигается \(Int(dwell)) мин", weight: 18))
            } else if dwell >= 20 {
                signals.append(Signal(code: "long_dwell", label: "не двигается \(Int(dwell)) мин", weight: 10))
            }
        }

        // Память: узнаёт ли AEGIS это место. nil — сказать пока нечего.
        if placeKnown == true {
            signals.append(Signal(code: "known_place", label: "привычное место", weight: -18))
        } else if placeKnown == false {
            signals.append(Signal(code: "unknown_place", label: "незнакомое место", weight: 8))
        }

        return signals
    }

    /// Опасны не факторы по отдельности, а их СОЧЕТАНИЯ (_compound_bonus).
    private static func compoundBonus(_ signals: [Signal]) -> (bonus: Int, note: String?) {
        let codes = Set(signals.map { $0.code })
        // Порядок правил = порядок убывания тревожности: возвращаем первое
        // совпавшее, поэтому сочетания с памятью стоят выше одноимённых без неё.
        if codes.isSuperset(of: ["night", "unknown_place", "long_dwell", "motionless"]) {
            return (30, "ночь, незнакомое место, полная неподвижность уже долго")
        }
        if codes.isSuperset(of: ["night", "unknown_place", "long_dwell"]) {
            return (24, "ночью надолго застрял в незнакомом месте")
        }
        if codes.isSuperset(of: ["night", "industrial", "motionless"]) {
            return (20, "ночь, нежилая зона и полная неподвижность вместе")
        }
        if codes.isSuperset(of: ["night", "industrial", "rushing"]) {
            return (18, "ночью быстрым шагом через нежилую зону")
        }
        if codes.isSuperset(of: ["far_deviation", "long_dwell"]) {
            return (16, "давно не двигается вдали от привычных мест")
        }
        if codes.isSuperset(of: ["industrial", "long_dwell"]) {
            return (14, "давно стоит в нежилой зоне")
        }
        if codes.isSuperset(of: ["night", "industrial"]) {
            return (12, "ночь в нежилой зоне")
        }
        if codes.isSuperset(of: ["night", "far_deviation"]) {
            return (12, "ночью далеко от привычных мест")
        }
        if codes.isSuperset(of: ["dusk", "unknown_place", "motionless"]) {
            return (11, "в поздний час замер в незнакомом месте")
        }
        if codes.isSuperset(of: ["industrial", "motionless"]) {
            return (10, "долго стоит в нежилой зоне")
        }
        if codes.isSuperset(of: ["night", "motionless"]) {
            return (8, "ночью долго не двигается")
        }
        if codes.isSuperset(of: ["rushing", "far_deviation"]) {
            return (8, "спешит вдали от привычных мест")
        }
        return (0, nil)
    }

    /// Больше согласованных факторов → выше уверенность (_confidence).
    private static func confidenceScore(_ signals: [Signal], compound: Bool) -> Int {
        let risky = signals.filter { $0.weight > 0 }.count
        var conf = 40 + 12 * risky
        if compound { conf += 15 }
        return clamp(conf, 0, 95)
    }

    /// Реплика ассистента + рекомендованное действие.
    ///
    /// v3 «Джарвис-режим»: обращение «сэр», по два-три варианта фраз на ярус
    /// (ротация по минуте, чтобы не долбить одной формулировкой) и конкретные
    /// протоколы действий вместо сухой констатации. Тон прежний: собранный,
    /// без паники.
    private static func voiceLine(suspicion: Int, reason: String,
                                  compoundNote: String?) -> (voice: String, action: String) {
        let focus = compoundNote ?? reason
        let seed = Int(Date().timeIntervalSince1970 / 60)
        func pick(_ variants: [String]) -> String { variants[abs(seed) % variants.count] }
        if suspicion >= 80 {
            return (pick([
                "Сэр, обстановка критическая: \(focus). Я снял все ограничения с канала SOS — одно слово, и тревога уйдёт вашему доверенному контакту.",
                "Сэр, картина серьёзно тревожная: \(focus). Протокол эвакуации готов, я держу связь на приоритете."
            ]), "prepare_sos")
        }
        if suspicion >= askThreshold {
            return (pick([
                "Сэр, мне не нравится картина: \(focus). Запускаю проверку связи — просто ответьте, и я сниму наблюдение.",
                "Сэр, обратите внимание: \(focus). Проверю, всё ли в порядке, — дождусь вашего слова."
            ]), "ask")
        }
        if suspicion >= 35 {
            return (pick([
                "Сэр, приглядываюсь: \(focus). Повода для тревоги пока нет, наблюдение продолжается.",
                "Заметил особенность, сэр: \(focus). Пока держу ситуацию в поле зрения."
            ]), "monitor")
        }
        return (pick([
            "Всё спокойно, сэр. Я на связи и слежу за обстановкой.",
            "Обстановка штатная, сэр. Датчики молчат, я на посту.",
            "Ничего подозрительного, сэр. Продолжаю наблюдение в фоновом режиме."
        ]), "monitor")
    }

    /// Уверенность словами — для интерфейса и реплик.
    private static func confidenceWord(_ c: Int) -> String {
        if c >= 80 { return "высокая" }
        if c >= 60 { return "уверенная" }
        if c >= 45 { return "средняя" }
        return "предварительная"
    }

    /// Оценка обстановки автономным мозгом AEGIS (assess_situation).
    /// `dwellMinutes` / `placeKnown` — из памяти (AegisMemory). По умолчанию nil:
    /// старые вызовы работают ровно как раньше, без единого нового сигнала.
    static func aegis(hour: Int?, placeType: String,
                      routeDeviation: String = "", speedMps: Double? = nil,
                      dwellMinutes: Double? = nil, placeKnown: Bool? = nil) -> SuspicionAssessment {
        let signals = collectSignals(hour: hour, placeType: placeType,
                                     routeDeviation: routeDeviation, speedMps: speedMps,
                                     dwellMinutes: dwellMinutes, placeKnown: placeKnown)
        var raw = 20 + signals.reduce(0) { $0 + $1.weight }
        let (bonus, compoundNote) = compoundBonus(signals)
        raw += bonus
        let suspicion = clamp(raw)

        // Причина — выявленное опасное сочетание, иначе самые весомые факторы.
        let risky = signals.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        let reason: String
        if let note = compoundNote {
            reason = note
        } else if !risky.isEmpty {
            reason = risky.prefix(3).map { $0.label }.joined(separator: ", ")
        } else {
            reason = "обычная обстановка"
        }

        let (voice, action) = voiceLine(suspicion: suspicion, reason: reason, compoundNote: compoundNote)
        let ask = suspicion >= askThreshold
        let confidence = confidenceScore(signals, compound: compoundNote != nil)
        return SuspicionAssessment(
            suspicion: suspicion,
            reason: reason,
            shouldAsk: ask,
            question: ask ? "Сэр, всё ли в порядке? Одного слова достаточно." : "",
            source: "aegis-v3",
            voice: voice,
            action: action,
            confidence: confidence,
            confidenceWord: confidenceWord(confidence)
        )
    }

    /// Обратная совместимость: прежний fallback теперь ведёт в AEGIS.
    static func fallback(hour: Int?, placeType: String, routeDeviation: String = "") -> SuspicionAssessment {
        aegis(hour: hour, placeType: placeType, routeDeviation: routeDeviation)
    }
}
