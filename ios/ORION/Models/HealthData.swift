import Foundation

/// Общее для всех записей журнала: время последней правки и метка удаления.
///
/// Зачем soft-delete: журнал — это история, а не текущий список. Если
/// просто убрать запись из массива, исчезнет и сам факт удаления: нельзя
/// ни восстановить запись, ни понять, что она была. Поэтому удаление —
/// это `deleted = true` + свежий `updatedAt`, а разрешение конфликтов
/// между копиями журнала — last-write-wins по `updatedAt`.
protocol JournalRecord: Codable, Identifiable {
    var id: UUID { get }
    var date: Date { get }
    var updatedAt: Date { get set }
    var deleted: Bool { get set }
}

/// Запись о весе.
struct WeightEntry: JournalRecord, Equatable {
    var id: UUID = UUID()
    var date: Date
    var kg: Double
    var updatedAt: Date = Date()
    var deleted: Bool = false

    init(id: UUID = UUID(), date: Date, kg: Double,
         updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id
        self.date = date
        self.kg = kg
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    // Старые файлы (health_weights.json) писались без updatedAt/deleted —
    // синтезированный декодер на них падает, поэтому декодируем терпимо.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        kg = try c.decode(Double.self, forKey: .kg)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? date
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

/// Быстрый тест ментального состояния (самооценка).
struct MoodEntry: JournalRecord, Equatable {
    var id: UUID = UUID()
    var date: Date
    /// Настроение 1..5 (1 — плохо, 5 — отлично).
    var mood: Int
    /// Уровень стресса 1..5 (1 — спокоен, 5 — сильный стресс).
    var stress: Int
    /// Часы сна за прошлую ночь.
    var sleepHours: Double
    var note: String = ""
    /// Ответы валидированных скринеров, по два пункта 0..3 (PHQ-2 — интерес
    /// и настроение, GAD-2 — нервозность и беспокойство). nil — не проходили:
    /// заполнять их каждый раз не нужно, они спрашивают про две недели сразу.
    var phq2: [Int]? = nil
    var gad2: [Int]? = nil
    var updatedAt: Date = Date()
    var deleted: Bool = false

    init(id: UUID = UUID(), date: Date, mood: Int, stress: Int, sleepHours: Double,
         note: String = "", phq2: [Int]? = nil, gad2: [Int]? = nil,
         updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id
        self.date = date
        self.mood = mood
        self.stress = stress
        self.sleepHours = sleepHours
        self.note = note
        self.phq2 = phq2
        self.gad2 = gad2
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        mood = try c.decode(Int.self, forKey: .mood)
        stress = try c.decode(Int.self, forKey: .stress)
        sleepHours = try c.decode(Double.self, forKey: .sleepHours)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        phq2 = try c.decodeIfPresent([Int].self, forKey: .phq2)
        gad2 = try c.decodeIfPresent([Int].self, forKey: .gad2)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? date
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

/// БАД / добавка / лекарство, которое принимает пользователь.
struct Supplement: JournalRecord, Equatable {
    var id: UUID = UUID()
    var name: String
    var dose: String = ""
    var schedule: String = ""   // напр. "утром", "2 раза в день"
    var date: Date = Date()
    var updatedAt: Date = Date()
    var deleted: Bool = false

    init(id: UUID = UUID(), name: String, dose: String = "", schedule: String = "",
         date: Date = Date(), updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id
        self.name = name
        self.dose = dose
        self.schedule = schedule
        self.date = date
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        dose = try c.decodeIfPresent(String.self, forKey: .dose) ?? ""
        schedule = try c.decodeIfPresent(String.self, forKey: .schedule) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? date
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

/// Свободная запись в журнале: всё, что человек хочет зафиксировать
/// словами («болит голова», «встреча в 19:00», «мне страшно»).
struct NoteEntry: JournalRecord, Equatable {
    var id: UUID = UUID()
    var date: Date
    var title: String = ""
    var text: String
    var updatedAt: Date = Date()
    var deleted: Bool = false

    init(id: UUID = UUID(), date: Date = Date(), title: String = "", text: String,
         updatedAt: Date = Date(), deleted: Bool = false) {
        self.id = id
        self.date = date
        self.title = title
        self.text = text
        self.updatedAt = updatedAt
        self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decode(String.self, forKey: .text)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? date
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

/// Снимок данных о состоянии за день (для шагомера и сводки).
struct HealthSnapshot: Codable, Equatable {
    var steps: Int = 0
    var distanceMeters: Double = 0
    var date: Date = Date()
}

// MARK: - Единый вид записи для истории и синхронизации

/// Тип записи журнала — совпадает с `kind` на сервере (`core/store.py`).
enum RecordKind: String, Codable, CaseIterable {
    case weight, mood, supplement, note

    var title: String {
        switch self {
        case .weight:     return "Вес"
        case .mood:       return "Самочувствие"
        case .supplement: return "Приём"
        case .note:       return "Заметка"
        }
    }

    var icon: String {
        switch self {
        case .weight:     return "scalemass"
        case .mood:       return "brain"
        case .supplement: return "pills"
        case .note:       return "text.alignleft"
        }
    }
}

/// Плоское представление любой записи: то, что летит на сервер и то, что
/// показывается в истории (в т.ч. записи, пришедшие от другого устройства).
struct SyncRecord: Codable, Identifiable, Equatable {
    var id: String
    var kind: RecordKind
    var createdAt: Date
    var updatedAt: Date
    var deleted: Bool
    var title: String
    var text: String
    var value: Double?
    var mood: Int?
    var stress: Int?
    var sleepHours: Double?

    enum CodingKeys: String, CodingKey {
        case id, kind, deleted, title, text, value, mood, stress
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sleepHours = "sleep_hours"
    }

    init(id: String, kind: RecordKind, createdAt: Date, updatedAt: Date,
         deleted: Bool = false, title: String = "", text: String = "",
         value: Double? = nil, mood: Int? = nil, stress: Int? = nil,
         sleepHours: Double? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.title = title
        self.text = text
        self.value = value
        self.mood = mood
        self.stress = stress
        self.sleepHours = sleepHours
    }

    // Сервер шлёт даты строкой ISO-8601 и может опускать любое поле —
    // декодируем терпимо, чтобы одна кривая запись не убила всю выдачу.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(RecordKind.self, forKey: .kind)) ?? .note
        updatedAt = SyncRecord.date(from: try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? Date()
        createdAt = SyncRecord.date(from: try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? updatedAt
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        mood = try c.decodeIfPresent(Int.self, forKey: .mood)
        stress = try c.decodeIfPresent(Int.self, forKey: .stress)
        sleepHours = try c.decodeIfPresent(Double.self, forKey: .sleepHours)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(SyncRecord.iso.string(from: createdAt), forKey: .createdAt)
        try c.encode(SyncRecord.iso.string(from: updatedAt), forKey: .updatedAt)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(title, forKey: .title)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(mood, forKey: .mood)
        try c.encodeIfPresent(stress, forKey: .stress)
        try c.encodeIfPresent(sleepHours, forKey: .sleepHours)
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(from raw: String??) -> Date? {
        guard let s = raw ?? nil, !s.isEmpty else { return nil }
        if let d = iso.date(from: s) { return d }
        // Сервер может отдать время без дробной части.
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// Строка для показа в списке истории.
    var summary: String {
        switch kind {
        case .weight:
            let kg = value.map { String(format: "%.1f кг", $0) } ?? "—"
            return text.isEmpty ? kg : "\(kg) · \(text)"
        case .mood:
            var parts: [String] = []
            if let m = mood { parts.append("настроение \(m)/5") }
            if let s = stress { parts.append("стресс \(s)/5") }
            if let h = sleepHours { parts.append(String(format: "сон %.1f ч", h)) }
            if !text.isEmpty { parts.append(text) }
            return parts.joined(separator: " · ")
        case .supplement:
            return [title, text].filter { !$0.isEmpty }.joined(separator: " · ")
        case .note:
            return [title, text].filter { !$0.isEmpty }.joined(separator: " — ")
        }
    }
}

// MARK: - Преобразование локальных записей в SyncRecord

extension WeightEntry {
    var syncRecord: SyncRecord {
        SyncRecord(id: id.uuidString, kind: .weight, createdAt: date, updatedAt: updatedAt,
                   deleted: deleted, value: kg)
    }
}

extension MoodEntry {
    var syncRecord: SyncRecord {
        SyncRecord(id: id.uuidString, kind: .mood, createdAt: date, updatedAt: updatedAt,
                   deleted: deleted, text: note, mood: mood, stress: stress,
                   sleepHours: sleepHours)
    }
}

extension Supplement {
    var syncRecord: SyncRecord {
        SyncRecord(id: id.uuidString, kind: .supplement, createdAt: date, updatedAt: updatedAt,
                   deleted: deleted, title: name,
                   text: [dose, schedule].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

extension NoteEntry {
    var syncRecord: SyncRecord {
        SyncRecord(id: id.uuidString, kind: .note, createdAt: date, updatedAt: updatedAt,
                   deleted: deleted, title: title, text: text)
    }
}
