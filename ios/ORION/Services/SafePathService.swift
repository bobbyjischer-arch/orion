import Foundation
import CoreLocation
import Combine

/// «Безопасный путь»: пользователь запускает таймер при входе в опасную
/// зону. Если до истечения времени он не подтвердит безопасность (кодом),
/// система автоматически активирует SOS.
@MainActor
final class SafePathService: ObservableObject {

    static let shared = SafePathService()

    @Published private(set) var isArmed = false
    @Published private(set) var deadline: Date?
    /// Сколько секунд осталось (для UI). 0 — когда не активен.
    @Published private(set) var remaining: TimeInterval = 0

    private var ticker: Timer?
    /// Источник текущей локации для авто-SOS.
    var locationProvider: (() -> CLLocation?)?

    private let sos = SOSService()
    private let notif = NotificationService.shared

    private init() {}

    // MARK: - Управление

    /// Запустить таймер на `minutes` минут.
    func arm(minutes: Int) {
        let secs = TimeInterval(max(1, minutes) * 60)
        let dl = Date().addingTimeInterval(secs)
        deadline = dl
        remaining = secs
        isArmed = true
        notif.notifySafePathArmed(minutes: minutes)
        // Бэкстоп на случай выгрузки приложения из памяти (Timer в фоне спит).
        notif.scheduleSafePathBackstop(deadline: dl)
        startTicker()
    }

    /// Проверка при возврате в foreground: если дедлайн уже прошёл, пока
    /// приложение спало — немедленно сработать (Timer этого не догонит).
    func checkExpiryOnForeground() {
        guard isArmed, let d = deadline else { return }
        if Date() >= d {
            triggerExpiry()
        } else {
            recomputeRemaining()
        }
    }

    /// Продлить активный таймер ещё на `minutes` минут.
    func extend(minutes: Int) {
        guard isArmed, let d = deadline else { return }
        deadline = d.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        recomputeRemaining()
    }

    /// Подтвердить безопасность и снять таймер. Возвращает true, если код верен.
    @discardableResult
    func confirmSafe(code: String) -> Bool {
        guard KeychainService.shared.verifyPasscode(code) else { return false }
        disarm()
        notif.notifySafePathCleared()
        return true
    }

    /// Снять таймер без проверки (например, из доверенного UI).
    func disarm() {
        ticker?.invalidate(); ticker = nil
        isArmed = false
        deadline = nil
        remaining = 0
        notif.cancelSafePathBackstop()
    }

    // MARK: - Тикер

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        recomputeRemaining()
        guard let d = deadline else { return }

        // Напоминание за минуту до срабатывания.
        if remaining <= 60 && remaining > 59 {
            notif.notifySafePathWarning()
        }

        if Date() >= d {
            triggerExpiry()
        }
    }

    private func recomputeRemaining() {
        guard let d = deadline else { remaining = 0; return }
        remaining = max(0, d.timeIntervalSinceNow)
    }

    private func triggerExpiry() {
        let loc = locationProvider?()
        disarm()
        // Авто-SOS — НЕ тихий: пользователь не отозвался, нужна реакция.
        Task { await sos.trigger(location: loc, silent: false) }
        notif.notifySafePathExpired()
    }

    /// Формат MM:SS для UI.
    var remainingString: String {
        let total = Int(remaining)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
