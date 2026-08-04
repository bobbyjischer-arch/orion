import SwiftUI
import Combine

// ╔══════════════════════════════════════════════════════════════╗
// ║  ПИТОМЕЦ — живой спутник внутри приложения                    ║
// ╚══════════════════════════════════════════════════════════════╝
//
// Питомец рисуется векторно (Views/PetSprite.swift), двигается своим
// движком (Services/PetEngine.swift) и размещается слоем поверх экранов
// (Views/PetLayer.swift). Здесь — только его «личность»: вид, настроение,
// привязанность и короткие реплики.
//
// Честно: питомец ничего не измеряет и никуда ничего не передаёт. Он
// реагирует на то, что и так видно на экране (уровень подозрения, тревога,
// время суток), и существует ради того, чтобы приложение про безопасность
// не выглядело как приборная панель.

// MARK: - Вид

enum PetSpecies: String, CaseIterable, Identifiable {
    case cat
    /// Пухлая кошечка: тот же кот, но круглее и на коротких лапках.
    case chonky = "chonky_cat"
    case dog, fox, bunny, hamster, penguin
    /// Совёнок: большая голова, кисточки на ушах, круглые глаза.
    case owl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cat:     return "Кот"
        case .chonky:  return "Пухлая кошечка"
        case .dog:     return "Пёс"
        case .fox:     return "Лиса"
        case .bunny:   return "Кролик"
        case .hamster: return "Хомяк"
        case .penguin: return "Пингвин"
        case .owl:     return "Совёнок"
        }
    }

    var defaultName: String {
        switch self {
        case .cat:     return "Мурзик"
        case .chonky:  return "Пышка"
        case .dog:     return "Рекс"
        case .fox:     return "Лиска"
        case .bunny:   return "Пушок"
        case .hamster: return "Хома"
        case .penguin: return "Пиня"
        case .owl:     return "Филя"
        }
    }
}

// MARK: - Окрас шерсти

/// Вариант окраса. Только естественные цвета: смысл в том, чтобы питомец
/// выглядел как настоящее животное, а не как перекрашенная иконка, поэтому
/// палитра акцентов интерфейса сюда намеренно не подключена.
struct PetFur: Identifiable, Equatable {
    let title: String
    let hex: String
    var id: String { hex }
}

extension PetSpecies {
    /// Естественные окрасы вида. **Первый — тот, которым питомец нарисован
    /// по умолчанию: его hex обязан совпадать с `PetLook.of(_:)`** (иначе
    /// свежая установка покажет один цвет, а выбранный «первый» — другой).
    var furOptions: [PetFur] {
        switch self {
        case .cat, .chonky:
            return [PetFur(title: "Серый",      hex: "9AA5B1"),
                    PetFur(title: "Рыжий",      hex: "E0904A"),
                    PetFur(title: "Чёрный",     hex: "33383F"),
                    PetFur(title: "Белый",      hex: "EDEAE5"),
                    PetFur(title: "Кремовый",   hex: "D9BFA0"),
                    PetFur(title: "Шоколадный", hex: "7A5B45")]
        case .dog:
            return [PetFur(title: "Палевый",    hex: "C99A63"),
                    PetFur(title: "Рыжий",      hex: "D9762F"),
                    PetFur(title: "Чёрный",     hex: "3A3430"),
                    PetFur(title: "Белый",      hex: "EFE6D8"),
                    PetFur(title: "Шоколадный", hex: "6E4A32"),
                    PetFur(title: "Серый",      hex: "9A9691")]
        case .fox:
            return [PetFur(title: "Рыжая",      hex: "E8834A"),
                    PetFur(title: "Огнёвка",    hex: "D65A22"),
                    PetFur(title: "Серебристая", hex: "6E7480"),
                    PetFur(title: "Песцовая",   hex: "EAE7E2"),
                    PetFur(title: "Крестовка",  hex: "8E5A3C")]
        case .bunny:
            return [PetFur(title: "Белый",      hex: "E8E4E1"),
                    PetFur(title: "Серый",      hex: "A9A6A2"),
                    PetFur(title: "Бежевый",    hex: "D8C3A5"),
                    PetFur(title: "Чёрный",     hex: "3B3733"),
                    PetFur(title: "Рыжий",      hex: "C08552")]
        case .hamster:
            return [PetFur(title: "Золотистый", hex: "E3B87C"),
                    PetFur(title: "Песочный",   hex: "EBD3A8"),
                    PetFur(title: "Серый",      hex: "A9A29A"),
                    PetFur(title: "Белый",      hex: "F2EDE6"),
                    PetFur(title: "Чёрный",     hex: "4A4038")]
        case .penguin:
            // У пингвина природа скупа на варианты — только оттенки спины.
            return [PetFur(title: "Классический", hex: "27303F"),
                    PetFur(title: "Антрацит",     hex: "1B222D"),
                    PetFur(title: "Синеватый",    hex: "33415A")]
        case .owl:
            return [PetFur(title: "Сипуха",     hex: "C79A6B"),
                    PetFur(title: "Неясыть",    hex: "8C8378"),
                    PetFur(title: "Бурый",      hex: "6E5741"),
                    PetFur(title: "Полярный",   hex: "EDE9E2"),
                    PetFur(title: "Ушастый",    hex: "5A4A3A")]
        }
    }

    /// Окрас «как нарисовано» — им же помечается выбор у нового пользователя.
    var defaultFurHex: String { furOptions.first?.hex ?? "9AA5B1" }
}

// MARK: - Настроение

enum PetMood: String {
    case calm, happy, playful, sleepy, worried, alert

    var title: String {
        switch self {
        case .calm:    return "спокоен"
        case .happy:   return "доволен"
        case .playful: return "играет"
        case .sleepy:  return "дремлет"
        case .worried: return "насторожен"
        case .alert:   return "начеку"
        }
    }
}

/// Что питомец делает прямо сейчас — от этого зависит поза при отрисовке.
enum PetActivity {
    case idle, walk, run, sit, sleep, play, alert
}

// MARK: - Личность

final class PetCompanion: ObservableObject {

    static let shared = PetCompanion()

    private let defaults: UserDefaults

    @Published private(set) var mood: PetMood = .calm
    /// Привязанность 0…1: растёт от внимания, медленно тает со временем.
    @Published private(set) var affection: Double
    /// Короткая реплика в облачке; гаснет сама.
    @Published private(set) var phrase: String?

    /// Растёт при каждом поглаживании — по нему рисуются сердечки.
    @Published private(set) var petCount: Int = 0

    private var phraseToken = 0
    private var lastPetAt: Date?

    private init() {
        let d = UserDefaults(suiteName: AppSettings.appGroup) ?? .standard
        self.defaults = d
        self.affection = (d.object(forKey: "pet.affection") as? Double) ?? 0.35

        // Привязанность тает, если про питомца забыли: примерно 1% в час.
        if let last = d.object(forKey: "pet.lastSeen") as? Date {
            let hours = max(0, -last.timeIntervalSinceNow / 3600)
            affection = max(0, affection - hours * 0.01)
        }
        d.set(Date(), forKey: "pet.lastSeen")
    }

    var species: PetSpecies {
        PetSpecies(rawValue: OrionAppearance.shared.petSpeciesID) ?? .cat
    }

    var displayName: String {
        let custom = OrionAppearance.shared.petName.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? species.defaultName : custom
    }

    /// Выбранный окрас. `nil` — «как нарисовано»: тогда путь отрисовки
    /// ровно тот же, что был до появления окрасов.
    var furColor: Color? {
        let hex = OrionAppearance.shared.petFurHex(for: species)
        return hex == species.defaultFurHex ? nil : Color(hex: hex)
    }

    // MARK: Взаимодействие

    /// Погладили.
    func pet() {
        petCount += 1
        affection = min(1, affection + 0.04)
        persist()
        if mood != .alert && mood != .worried {
            mood = .happy
        }
        say(Self.petPhrases.randomElement())
    }

    /// Поиграли (ткнули в питомца на карте / он догнал точку).
    func play() {
        affection = min(1, affection + 0.02)
        persist()
        if mood != .alert { mood = .playful }
        say(Self.playPhrases.randomElement())
    }

    /// Реакция на оценку обстановки: чем выше подозрение, тем собраннее питомец.
    func react(suspicion: Int) {
        switch suspicion {
        case 80...:
            if mood != .alert { say(Self.alertPhrases.randomElement()) }
            mood = .alert
        case 60..<80:
            if mood != .worried && mood != .alert { say(Self.worriedPhrases.randomElement()) }
            mood = .worried
        default:
            if mood == .alert || mood == .worried { mood = .calm }
        }
    }

    /// Тревога поднята — питомец рядом и не спит.
    func react(sosActive: Bool) {
        if sosActive {
            mood = .alert
            say("Я рядом.")
        } else if mood == .alert {
            mood = .calm
        }
    }

    /// Ночью питомец засыпает, днём просыпается. Тревога важнее сна.
    func nightCheck(now: Date = Date()) {
        guard mood != .alert && mood != .worried else { return }
        let hour = Calendar.current.component(.hour, from: now)
        if hour >= 23 || hour < 6 {
            mood = .sleepy
        } else if mood == .sleepy {
            mood = .calm
        }
    }

    /// Поза по настроению — движок берёт её как базовую.
    var baseActivity: PetActivity {
        switch mood {
        case .sleepy:  return .sleep
        case .alert:   return .alert
        case .playful: return .play
        case .worried: return .sit
        default:       return .idle
        }
    }

    // MARK: Реплики

    func say(_ text: String?) {
        guard let text = text, !text.isEmpty else { return }
        phrase = text
        phraseToken += 1
        let token = phraseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self, self.phraseToken == token else { return }
            self.phrase = nil
        }
    }

    private func persist() {
        defaults.set(affection, forKey: "pet.affection")
        defaults.set(Date(), forKey: "pet.lastSeen")
    }

    // Реплики короткие и без обещаний: питомец не охраняет и не спасает,
    // он просто рядом. Обещать безопасность в приложении про безопасность —
    // плохая идея.
    private static let petPhrases = [
        "Мур.", "Ещё?", "Хорошо сидим.", "Я тут.", "Приятно.",
    ]
    private static let playPhrases = [
        "Догоню!", "Ага, попалась.", "Ещё разок.", "Быстрее!",
    ]
    private static let worriedPhrases = [
        "Что-то не то…", "Я насторожился.", "Держусь рядом.",
    ]
    private static let alertPhrases = [
        "Я не сплю.", "Смотрю в оба.", "Рядом.",
    ]
}
