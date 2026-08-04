import Foundation
import UIKit

/// Jailbreak detection service
final class JailbreakDetector {

    static let shared = JailbreakDetector()

    private init() {}

    // MARK: - Detection

    var isJailbroken: Bool {
        // Check multiple indicators
        return checkSuspiciousFiles() ||
               checkSuspiciousApps() ||
               checkSystemWriteAccess() ||
               checkSymlinks() ||
               checkDyldEnvironment()
    }

    // MARK: - Detection Methods

    private func checkSuspiciousFiles() -> Bool {
        let paths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/private/var/lib/apt/",
            "/private/var/lib/cydia",
            "/private/var/stash",
            "/usr/libexec/sftp-server",
            "/usr/bin/ssh"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }

        return false
    }

    private func checkSuspiciousApps() -> Bool {
        guard let schemes = ["cydia://", "sileo://", "zbra://", "filza://"] as? [String] else {
            return false
        }

        for scheme in schemes {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                return true
            }
        }

        return false
    }

    private func checkSystemWriteAccess() -> Bool {
        let testPath = "/private/jailbreak_test.txt"
        do {
            try "test".write(toFile: testPath, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: testPath)
            return true
        } catch {
            return false
        }
    }

    // ПРИМЕЧАНИЕ: проверка через fork() удалена — символ fork() недоступен
    // в iOS SDK (компилятор помечает его unavailable). Детекция джейлбрейка
    // опирается на остальные методы (файлы, схемы, запись, симлинки, DYLD).

    private func checkSymlinks() -> Bool {
        do {
            let path = "/Applications"
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let type = attributes[.type] as? FileAttributeType, type == .typeSymbolicLink {
                return true
            }
        } catch {
            return false
        }
        return false
    }

    private func checkDyldEnvironment() -> Bool {
        // Check for suspicious environment variables
        if let _ = getenv("DYLD_INSERT_LIBRARIES") {
            return true
        }
        return false
    }

    // MARK: - User Notification

    func warnIfJailbroken() -> String? {
        if isJailbroken {
            return """
            ⚠️ Обнаружен Jailbreak

            Это устройство взломано. O.R.I.O.N. может работать нестабильно, \
            а ваши данные могут быть скомпрометированы.

            Рекомендуется использовать приложение только на защищённых устройствах.
            """
        }
        return nil
    }
}
