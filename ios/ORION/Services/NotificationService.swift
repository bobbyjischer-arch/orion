import Foundation
import UserNotifications

final class NotificationService {

    static let shared = NotificationService()
    private init() {}

    // MARK: - Разрешение

    func requestPermission() async {
        try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - Уведомления

    /// Сервер недоступен
    func notifyServerDown() {
        send(
            id:    "server_down",
            title: "⚠️ O.R.I.O.N. — нет связи",
            body:  "Сервер недоступен. Координаты не отправляются.",
            sound: .default
        )
    }

    /// Сервер восстановлен
    func notifyServerRestored() {
        // Убираем предыдущее уведомление о потере связи
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["server_down"])
        send(
            id:    "server_restored",
            title: "✅ O.R.I.O.N. — связь восстановлена",
            body:  "Сервер снова доступен.",
            sound: .default
        )
    }

    /// SOS отправлен
    func notifySOSSent(contactCount: Int) {
        send(
            id:    "sos_sent",
            title: "🆘 SOS отправлен",
            body:  "Уведомлено контактов: \(contactCount). Помощь в пути.",
            sound: UNNotificationSound(named: UNNotificationSoundName("sos.caf"))
        )
    }

    /// Тревога от сервера
    func notifyAlert(reason: String) {
        send(
            id:    "orion_alert",
            title: "🚨 O.R.I.O.N. — ТРЕВОГА",
            body:  reason,
            sound: .defaultCritical
        )
    }

    /// Geofence event
    func notifyGeofenceEvent(_ message: String) {
        send(
            id:    "geofence_\(UUID().uuidString)",
            title: "📍 O.R.I.O.N. — Геозона",
            body:  message,
            sound: .default
        )
    }

    /// Low battery warning
    func notifyLowBattery(level: Int) {
        send(
            id:    "low_battery",
            title: "🔋 O.R.I.O.N. — Низкий заряд",
            body:  "Батарея устройства: \(level)%. Рекомендуется зарядка.",
            sound: .default
        )
    }

    /// Device stationary alert
    func notifyStationaryDevice(hours: Int) {
        send(
            id:    "stationary_device",
            title: "⏱️ O.R.I.O.N. — Устройство неподвижно",
            body:  "Устройство не двигалось \(hours) ч. Проверьте состояние.",
            sound: .default
        )
    }

    /// «Безопасный путь» активирован
    func notifySafePathArmed(minutes: Int) {
        send(
            id:    "safepath_armed",
            title: "🛡 O.R.I.O.N. — Безопасный путь",
            body:  "Таймер на \(minutes) мин. Подтверди кодом по прибытии, иначе сработает SOS.",
            sound: .default
        )
    }

    /// Скоро сработает (за минуту)
    func notifySafePathWarning() {
        send(
            id:    "safepath_warning",
            title: "⏳ O.R.I.O.N. — осталась минута",
            body:  "Подтверди безопасность, иначе будет отправлен SOS.",
            sound: .defaultCritical
        )
    }

    /// Таймер истёк — SOS отправлен
    func notifySafePathExpired() {
        send(
            id:    "safepath_expired",
            title: "🆘 O.R.I.O.N. — SOS",
            body:  "Время вышло без подтверждения. Контакты уведомлены.",
            sound: .defaultCritical
        )
    }

    /// Безопасность подтверждена — таймер снят
    func notifySafePathCleared() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["safepath_armed", "safepath_warning"])
        send(
            id:    "safepath_cleared",
            title: "✅ O.R.I.O.N. — Прибытие подтверждено",
            body:  "Безопасный путь завершён.",
            sound: .default
        )
    }

    /// Приближение к точке интереса — вопрос о намерении
    func notifyApproachingPOI(name: String, category: String) {
        send(
            id:    "poi_approach_\(name)",
            title: "📍 O.R.I.O.N. — \(name)",
            body:  "Похоже, ты направляешься в «\(name)» (\(category)). Всё по плану?",
            sound: .default
        )
    }

    /// Высокий уровень подозрения от «мозга»
    func notifySuspicion(level: Int, question: String) {
        send(
            id:    "suspicion",
            title: "🧠 O.R.I.O.N. — \(level)/100",
            body:  question,
            sound: .defaultCritical
        )
    }

    /// Unusual location detected
    func notifyUnusualLocation(location: String) {
        send(
            id:    "unusual_location",
            title: "🗺️ O.R.I.O.N. — Необычное местоположение",
            body:  "Обнаружено в: \(location)",
            sound: .default
        )
    }

    // MARK: - «Безопасный путь»: бэкстоп на фоне

    /// Планирует уведомления-бэкстопы на будущее, чтобы дед-мен таймер
    /// сработал, даже если приложение выгружено из памяти (обычный Timer
    /// в фоне приостанавливается). Ставим предупреждение за минуту и алерт
    /// в момент дедлайна. Реальный авто-SOS сработает, когда приложение
    /// проснётся (или по нажатию на уведомление); эти алерты гарантируют,
    /// что пользователь/контакты будут оповещены при истечении времени.
    func scheduleSafePathBackstop(deadline: Date) {
        cancelSafePathBackstop()
        let now = Date()
        let warnAt = deadline.addingTimeInterval(-60).timeIntervalSince(now)
        if warnAt > 0 {
            scheduleAt(id: "safepath_bg_warning", after: warnAt,
                       title: "⏳ O.R.I.O.N. — осталась минута",
                       body: "Открой приложение и подтверди безопасность, иначе SOS.",
                       sound: .defaultCritical)
        }
        let fireAt = deadline.timeIntervalSince(now)
        if fireAt > 0 {
            scheduleAt(id: "safepath_bg_expired", after: fireAt,
                       title: "🆘 O.R.I.O.N. — время вышло",
                       body: "Безопасный путь не подтверждён. Открой приложение — отправляется SOS.",
                       sound: .defaultCritical)
        }
    }

    func cancelSafePathBackstop() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["safepath_bg_warning", "safepath_bg_expired"])
    }

    private func scheduleAt(id: String, after seconds: TimeInterval,
                            title: String, body: String, sound: UNNotificationSound?) {
        let content   = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = sound
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // MARK: - Внутренний метод

    private func send(id: String, title: String, body: String, sound: UNNotificationSound?) {
        let content        = UNMutableNotificationContent()
        content.title      = title
        content.body       = body
        content.sound      = sound

        let request = UNNotificationRequest(
            identifier: id,
            content:    content,
            trigger:    nil   // доставить немедленно
        )
        UNUserNotificationCenter.current().add(request)
    }
}
