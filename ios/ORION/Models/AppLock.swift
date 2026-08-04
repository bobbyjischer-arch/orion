import Foundation
import Combine

/// Управляет состоянием блокировки.
/// Не зависит от UIKit — совместим с любым таргетом.
final class AppLock: ObservableObject {

    static let shared = AppLock()

    @Published var isUnlocked  = false
    @Published var showWrongPW = false
    @Published var biometricEnabled = true // User preference for biometric auth

    /// Код доступа ещё не создан — первый запуск. Экран блокировки в этом
    /// состоянии просит придумать код, а не ввести его.
    @Published var needsSetup: Bool

    private let keychain = KeychainService.shared
    private let biometric = BiometricService.shared
    private var lockTimer: Timer?
    private let autoLockDelay: TimeInterval = 10

    private init() {
        // Кода по умолчанию нет намеренно: исходники открыты, и любой
        // предустановленный код был бы известен всем, кто их читал —
        // а это единственная дверь в приложение. Код создаёт сам владелец
        // при первом запуске (см. setupPasscode). Duress-код («тихий
        // сигнал») тоже не задан заранее: он задаётся в настройках, иначе
        // известный по исходникам «0000» открывал бы приложение с тихой
        // отправкой SOS. См. attempt(_:).
        needsSetup = !keychain.hasPasscode

        // Используем строковые имена нотификаций — не требуют UIKit
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBackground),
            name:     NSNotification.Name("UIApplicationDidEnterBackgroundNotification"),
            object:   nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillForeground),
            name:     NSNotification.Name("UIApplicationWillEnterForegroundNotification"),
            object:   nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public

    /// Создать код доступа на первом запуске. Возвращает false, если код
    /// пустой или уже создан — перезаписать чужой код без старого нельзя.
    @discardableResult
    func setupPasscode(_ code: String) -> Bool {
        guard !code.isEmpty, !keychain.hasPasscode else { return false }
        try? keychain.savePasscode(code)
        needsSetup = !keychain.hasPasscode
        guard !needsSetup else { return false }
        isUnlocked = true
        return true
    }

    @discardableResult
    func attempt(_ code: String) -> Bool {
        // «Тихий сигнал»: duress-код выглядит как обычная разблокировка,
        // но скрытно запускает тихий SOS без следов на экране.
        if keychain.verifyDuressCode(code) {
            triggerSilentDistress()
            isUnlocked  = true
            showWrongPW = false
            return true
        }
        if keychain.verifyPasscode(code) {
            isUnlocked  = true
            showWrongPW = false
            return true
        } else {
            showWrongPW = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showWrongPW = false
            }
            return false
        }
    }

    /// Скрытая активация SOS при вводе duress-кода. Без UI и звука.
    /// location: nil — SOSService возьмёт последнюю сохранённую точку из настроек.
    private func triggerSilentDistress() {
        Task { @MainActor in
            await SOSService().trigger(location: nil, silent: true)
        }
    }

    func changePasscode(old: String, new: String) -> Bool {
        guard keychain.verifyPasscode(old) else { return false }
        // Совпадение с кодом тревоги превратило бы обычный вход в тихий SOS:
        // attempt(_:) проверяет duress первым.
        guard !keychain.verifyDuressCode(new) else { return false }
        try? keychain.savePasscode(new)
        return true
    }

    /// Задать/сменить duress-код («тихий сигнал»). Не должен совпадать с
    /// основным паролем, иначе обычная разблокировка станет тревогой.
    @discardableResult
    func setDuressCode(_ code: String) -> Bool {
        guard !code.isEmpty, !keychain.verifyPasscode(code) else { return false }
        try? keychain.saveDuressCode(code)
        return true
    }

    var hasDuressCode: Bool { keychain.hasDuressCode }

    func authenticateWithBiometric() async -> Bool {
        // Пока код не создан, Face ID открывать нечего: владелец ещё не
        // подтвердил, что телефон его, — сначала экран создания кода.
        guard !needsSetup, biometricEnabled, biometric.isBiometricAvailable else {
            return false
        }

        let result = await biometric.authenticate()
        switch result {
        case .success:
            await MainActor.run {
                isUnlocked = true
            }
            return true
        case .failure:
            return false
        }
    }

    func lock() {
        isUnlocked = false
    }

    // Вызывается когда приложение ушло в фон — запускаем таймер блокировки
    func handleBackground() {
        lockTimer = Timer.scheduledTimer(withTimeInterval: autoLockDelay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.isUnlocked = false }
        }
    }

    // Вызывается когда приложение вернулось на передний план — отменяем таймер
    func handleForeground() {
        lockTimer?.invalidate()
        lockTimer = nil
    }

    // MARK: - Notification handlers

    @objc private func appDidBackground() { handleBackground() }
    @objc private func appWillForeground() { handleForeground() }
}
