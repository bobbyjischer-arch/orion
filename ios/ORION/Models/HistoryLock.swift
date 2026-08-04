import Foundation
import Combine
import UIKit

/// Код-пароль на историю записей.
///
/// Смотреть историю можно свободно — а вот **править и удалять** записи
/// разрешено только после ввода кода. Код хранится в Keychain как SHA-256
/// хеш (`KeychainService.Key.historyCode`); «дефолтного» кода нет — при
/// первом обращении его нужно создать, иначе защита была бы бутафорской.
///
/// После верного кода открывается короткое окно доступа (`unlockWindow`),
/// чтобы не вводить код на каждую правку подряд. Окно закрывается само,
/// при уходе приложения в фон и вручную (`lock()`).
@MainActor
final class HistoryLock: ObservableObject {

    static let shared = HistoryLock()

    /// Сколько времени действует разовый ввод кода.
    static let unlockWindow: TimeInterval = 120

    @Published private(set) var isUnlocked = false
    @Published private(set) var isConfigured: Bool
    /// Текст последней ошибки для UI (неверный код, короткий код и т.п.).
    @Published var lastError: String?

    private var expiryTimer: Timer?
    private let keychain = KeychainService.shared

    private init() {
        isConfigured = KeychainService.shared.hasHistoryCode
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }

    /// Минимальная длина кода. Четыре цифры — как у остальных кодов ORION.
    static let minLength = 4

    /// Создать код в первый раз. Возвращает false с текстом ошибки в
    /// `lastError`, если код слишком короткий или уже задан.
    @discardableResult
    func setInitialCode(_ code: String) -> Bool {
        guard !isConfigured else {
            lastError = "Код уже задан — смените его в настройках"
            return false
        }
        guard code.count >= HistoryLock.minLength else {
            lastError = "Минимум \(HistoryLock.minLength) символа"
            return false
        }
        do {
            try keychain.saveHistoryCode(code)
        } catch {
            lastError = "Не удалось сохранить код"
            return false
        }
        isConfigured = true
        lastError = nil
        unlock()
        return true
    }

    /// Проверить код и открыть окно доступа.
    @discardableResult
    func attempt(_ code: String) -> Bool {
        guard isConfigured else {
            lastError = "Код не задан"
            return false
        }
        guard keychain.verifyHistoryCode(code) else {
            lastError = "Неверный код"
            return false
        }
        lastError = nil
        unlock()
        return true
    }

    /// Сменить код (нужен текущий).
    @discardableResult
    func changeCode(old: String, new: String) -> Bool {
        guard new.count >= HistoryLock.minLength else {
            lastError = "Минимум \(HistoryLock.minLength) символа"
            return false
        }
        guard keychain.changeHistoryCode(old: old, new: new) else {
            lastError = "Неверный текущий код"
            return false
        }
        lastError = nil
        return true
    }

    func lock() {
        isUnlocked = false
        expiryTimer?.invalidate()
        expiryTimer = nil
    }

    private func unlock() {
        isUnlocked = true
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: HistoryLock.unlockWindow,
                                           repeats: false) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }
}
