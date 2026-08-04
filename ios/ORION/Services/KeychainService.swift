import Foundation
import Security

/// Secure storage service using iOS Keychain
final class KeychainService {

    static let shared = KeychainService()

    private init() {}

    enum KeychainError: Error {
        case itemNotFound
        case duplicateItem
        case invalidData
        case unexpectedStatus(OSStatus)
    }

    // MARK: - Keys

    enum Key: String {
        case appPasscode = "com.stark.orion.passcode"
        case duressPasscode = "com.stark.orion.duress"
        case telegramBotToken = "com.stark.orion.telegram.token"
        case serverAuthToken = "com.stark.orion.server.token"
        case openRouterKey = "com.stark.orion.openrouter.key"
        case cascadeSecret = "com.stark.orion.cascade.secret"
        /// Код-пароль на правку и удаление записей в истории.
        case historyCode = "com.stark.orion.history.code"
    }

    // MARK: - Save

    func save(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            try update(value, for: key)
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Retrieve

    func retrieve(for key: Key) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw status == errSecItemNotFound ? KeychainError.itemNotFound : KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return string
    }

    // MARK: - Update

    private func update(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Delete

    func delete(for key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Encrypted Data Storage

    func saveEncrypted<T: Codable>(_ value: T, for key: String) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            try updateEncrypted(value, for: key)
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func retrieveEncrypted<T: Codable>(for key: String, as type: T.Type) throws -> T {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw status == errSecItemNotFound ? KeychainError.itemNotFound : KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }

        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    private func updateEncrypted<T: Codable>(_ value: T, for key: String) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

// MARK: - Convenience Extensions

extension KeychainService {

    /// Check if passcode exists in Keychain
    var hasPasscode: Bool {
        (try? retrieve(for: .appPasscode)) != nil
    }

    /// Verify passcode against stored hash
    func verifyPasscode(_ input: String) -> Bool {
        guard let stored = try? retrieve(for: .appPasscode) else {
            return false
        }
        return hashPasscode(input) == stored
    }

    /// Save passcode as SHA-256 hash
    func savePasscode(_ passcode: String) throws {
        let hashed = hashPasscode(passcode)
        try save(hashed, for: .appPasscode)
    }

    /// Есть ли заданный duress-код («тихий сигнал»)
    var hasDuressCode: Bool {
        (try? retrieve(for: .duressPasscode)) != nil
    }

    /// Проверить duress-код. Пустой непустой ввод не совпадает с незаданным кодом.
    func verifyDuressCode(_ input: String) -> Bool {
        guard let stored = try? retrieve(for: .duressPasscode), !stored.isEmpty else {
            return false
        }
        return hashPasscode(input) == stored
    }

    /// Сохранить duress-код как SHA-256 хеш.
    func saveDuressCode(_ passcode: String) throws {
        try save(hashPasscode(passcode), for: .duressPasscode)
    }

    /// Удалить duress-код.
    func clearDuressCode() {
        try? delete(for: .duressPasscode)
    }

    /// Задан ли ключ доступа к core (X-Orion-Key).
    var hasServerKey: Bool {
        !((try? retrieve(for: .serverAuthToken)) ?? "").isEmpty
    }

    /// Задан ли общий секрет каскадного шифрования.
    var hasCascadeSecret: Bool {
        !((try? retrieve(for: .cascadeSecret)) ?? "").isEmpty
    }

    /// Задан ли код-пароль истории записей.
    var hasHistoryCode: Bool {
        guard let stored = try? retrieve(for: .historyCode) else { return false }
        return !stored.isEmpty
    }

    /// Проверить код-пароль истории. Если код не задан — доступа нет,
    /// его сначала нужно создать (никаких «дефолтных» кодов).
    func verifyHistoryCode(_ input: String) -> Bool {
        guard let stored = try? retrieve(for: .historyCode), !stored.isEmpty else {
            return false
        }
        return hashPasscode(input) == stored
    }

    /// Сохранить код-пароль истории как SHA-256 хеш.
    func saveHistoryCode(_ code: String) throws {
        try save(hashPasscode(code), for: .historyCode)
    }

    /// Сменить код-пароль истории (нужен текущий).
    func changeHistoryCode(old: String, new: String) -> Bool {
        guard verifyHistoryCode(old) else { return false }
        do { try saveHistoryCode(new); return true } catch { return false }
    }

    private func hashPasscode(_ passcode: String) -> String {
        guard let data = passcode.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CommonCrypto Import

import CommonCrypto
