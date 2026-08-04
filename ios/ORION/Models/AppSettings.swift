import Foundation
import Combine

/// Единственный источник правды для всех настроек приложения.
/// Использует @AppStorage-совместимый UserDefaults через App Group
/// чтобы виджет мог читать те же данные.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()
    /// Общий контейнер приложения и виджета.
    static let appGroup = "group.com.stark.orion"

    /// URL файла в общем контейнере App Group, либо — если контейнер
    /// недоступен (например, сайдлоад с бесплатным Apple-аккаунтом) —
    /// в Documents приложения. Гарантирует, что данные сохраняются.
    static func sharedFileURL(_ name: String) -> URL? {
        let fm = FileManager.default
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return container.appendingPathComponent(name)
        }
        return fm.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(name)
    }

    private let defaults: UserDefaults

    // MARK: - Настройки сервера
    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: "serverURL") }
    }

    // MARK: - Геолокация
    @Published var intervalMinutes: Int {
        didSet { defaults.set(intervalMinutes, forKey: "intervalMinutes") }
    }

    // MARK: - SOS
    @Published var sosContacts: [SOSContact] {
        didSet {
            if let data = try? JSONEncoder().encode(sosContacts) {
                defaults.set(data, forKey: "sosContacts")
            }
        }
    }
    @Published var sosBotToken: String {
        didSet {
            // Save to Keychain instead of UserDefaults
            try? KeychainService.shared.save(sosBotToken, for: .telegramBotToken)
        }
    }

    // MARK: - «Мозг» (анализ через OpenRouter)
    @Published var openRouterKey: String {
        didSet {
            // Ключ — в Keychain, не в UserDefaults
            try? KeychainService.shared.save(openRouterKey, for: .openRouterKey)
        }
    }
    @Published var openRouterModel: String {
        didSet { defaults.set(openRouterModel, forKey: "openRouterModel") }
    }
    @Published var suspicionEnabled: Bool {
        didSet { defaults.set(suspicionEnabled, forKey: "suspicionEnabled") }
    }
    /// Полный URL chat/completions любого OpenAI-совместимого шлюза
    /// (OpenRouter, прокси для Claude и т.п.).
    @Published var llmEndpoint: String {
        didSet { defaults.set(llmEndpoint, forKey: "llmEndpoint") }
    }
    @Published var voiceEnabled: Bool {
        didSet { defaults.set(voiceEnabled, forKey: "voiceEnabled") }
    }

    // MARK: - Карта / маршрут
    @Published var routeOpacity: Double {       // 0.1...1.0
        didSet { defaults.set(routeOpacity, forKey: "routeOpacity") }
    }
    @Published var routeWidth: Double {         // ширина линии
        didSet { defaults.set(routeWidth, forKey: "routeWidth") }
    }
    @Published var routeColorName: String {     // cyan/green/orange/purple/red
        didSet { defaults.set(routeColorName, forKey: "routeColorName") }
    }
    @Published var routeGradient: Bool {        // прозрачность вдоль маршрута
        didSet { defaults.set(routeGradient, forKey: "routeGradient") }
    }

    // MARK: - Последняя известная точка (для виджета)
    @Published var lastLatitude: Double {
        didSet { defaults.set(lastLatitude, forKey: "lastLatitude") }
    }
    @Published var lastLongitude: Double {
        didSet { defaults.set(lastLongitude, forKey: "lastLongitude") }
    }
    @Published var lastLocationDate: Date? {
        didSet { defaults.set(lastLocationDate, forKey: "lastLocationDate") }
    }
    @Published var systemStatus: String {
        didSet { defaults.set(systemStatus, forKey: "systemStatus") }
    }
    @Published var serverReachable: Bool {
        didSet { defaults.set(serverReachable, forKey: "serverReachable") }
    }
    @Published var totalPointsSent: Int {
        didSet { defaults.set(totalPointsSent, forKey: "totalPointsSent") }
    }

    // MARK: - Идентификация устройства на сервере

    /// Постоянный идентификатор устройства (создаётся один раз).
    @Published var deviceID: String {
        didSet { defaults.set(deviceID, forKey: "deviceID") }
    }
    /// Как устройство подписано на сервере и в дашборде.
    @Published var deviceName: String {
        didSet { defaults.set(deviceName, forKey: "deviceName") }
    }

    // MARK: - SOS Auto-capture
    @Published var sosAutoCapture: Bool {
        didSet { defaults.set(sosAutoCapture, forKey: "sosAutoCapture") }
    }
    @Published var fallDetectionEnabled: Bool {
        didSet { defaults.set(fallDetectionEnabled, forKey: "fallDetectionEnabled") }
    }

    private init() {
        // App Group даёт доступ виджету к тем же данным
        let d = UserDefaults(suiteName: AppSettings.appGroup) ?? .standard
        self.defaults = d

        self.serverURL        = d.string(forKey: "serverURL")       ?? "http://192.168.1.1:8000"
        self.intervalMinutes  = d.integer(forKey: "intervalMinutes").nonZeroOr(5)

        // Load bot token from Keychain instead of UserDefaults
        self.sosBotToken      = (try? KeychainService.shared.retrieve(for: .telegramBotToken)) ?? ""

        // «Мозг» — ключ из Keychain, модель/тумблер из UserDefaults
        self.openRouterKey    = (try? KeychainService.shared.retrieve(for: .openRouterKey)) ?? ""
        // Дефолт = актуальная рабочая free-модель. Миграция: заменяем
        // устаревший hermes-id (его OpenRouter снял с бесплатного хостинга).
        let savedModel = d.string(forKey: "openRouterModel")
        if savedModel == nil || savedModel == "nousresearch/hermes-3-llama-3.1-405b:free" {
            self.openRouterModel = "deepseek/deepseek-chat-v3-0324:free"
        } else {
            self.openRouterModel = savedModel!
        }
        self.suspicionEnabled = d.object(forKey: "suspicionEnabled") as? Bool ?? true
        self.voiceEnabled     = d.object(forKey: "voiceEnabled") as? Bool ?? true
        self.llmEndpoint      = d.string(forKey: "llmEndpoint") ?? "https://openrouter.ai/api/v1/chat/completions"

        self.routeOpacity   = (d.object(forKey: "routeOpacity") as? Double) ?? 0.8
        self.routeWidth     = (d.object(forKey: "routeWidth") as? Double) ?? 4.0
        self.routeColorName = d.string(forKey: "routeColorName") ?? "cyan"
        self.routeGradient  = d.object(forKey: "routeGradient") as? Bool ?? true

        self.lastLatitude     = d.double(forKey: "lastLatitude")
        self.lastLongitude    = d.double(forKey: "lastLongitude")
        self.lastLocationDate = d.object(forKey: "lastLocationDate") as? Date
        self.systemStatus     = d.string(forKey: "systemStatus")    ?? "offline"
        self.serverReachable  = d.bool(forKey: "serverReachable")
        self.totalPointsSent  = d.integer(forKey: "totalPointsSent")
        self.sosAutoCapture   = d.bool(forKey: "sosAutoCapture")
        self.fallDetectionEnabled = d.bool(forKey: "fallDetectionEnabled")

        // Идентификатор устройства создаём один раз и больше не меняем —
        // по нему владелец узнаёт присланные записи и трек.
        if let saved = d.string(forKey: "deviceID"), !saved.isEmpty {
            self.deviceID = saved
        } else {
            let generated = UUID().uuidString
            d.set(generated, forKey: "deviceID")
            self.deviceID = generated
        }
        self.deviceName = d.string(forKey: "deviceName") ?? "ORION"

        if let data = d.data(forKey: "sosContacts"),
           let contacts = try? JSONDecoder().decode([SOSContact].self, from: data) {
            self.sosContacts = contacts
        } else {
            self.sosContacts = []
        }
    }
}

// MARK: - SOS Contact Model
struct SOSContact: Codable, Identifiable {
    var id: UUID
    var name: String
    var telegramChatID: String

    init(id: UUID = UUID(), name: String, telegramChatID: String) {
        self.id             = id
        self.name           = name
        self.telegramChatID = telegramChatID
    }
}

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int { self == 0 ? fallback : self }
}
