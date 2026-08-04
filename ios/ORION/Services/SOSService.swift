import Foundation
import CoreLocation

@MainActor
final class SOSService: ObservableObject {

    @Published var isSending   = false
    @Published var lastResult: SOSResult?

    enum SOSResult {
        case success(contactsNotified: Int)
        case partialSuccess(contactsNotified: Int, total: Int)
        case serverOnly
        case failed(String)
    }

    private let network  = NetworkService()
    private let notif    = NotificationService.shared
    private let settings = AppSettings.shared

    /// - Parameter silent: тихий режим — без локальных уведомлений/звука
    ///   на устройстве (для duress-кода и «Безопасного пути»).
    func trigger(location: CLLocation?, silent: Bool = false) async {
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }

        let lat = location?.coordinate.latitude  ?? settings.lastLatitude
        let lon = location?.coordinate.longitude ?? settings.lastLongitude
        let lastSeen = settings.lastLocationDate

        // 1. Пробуем через сервер (он уведомит бота, бот — контакты)
        let serverOK = await network.sendSOS(lat: lat, lon: lon, serverURL: settings.serverURL)

        // 2. Прямой Telegram как резервный канал (всегда, для надёжности)
        let directCount = await network.sendSOSViaTelegram(
            botToken: settings.sosBotToken,
            contacts: settings.sosContacts,
            lat:      lat,
            lon:      lon,
            lastSeen: lastSeen,
            silent:   silent
        )

        let total = settings.sosContacts.count
        // В тихом режиме не показываем локальное уведомление — никаких следов.
        if !silent {
            notif.notifySOSSent(contactCount: max(directCount, serverOK ? 1 : 0))
        }

        if directCount == total && total > 0 {
            lastResult = .success(contactsNotified: directCount)
        } else if directCount > 0 {
            lastResult = .partialSuccess(contactsNotified: directCount, total: total)
        } else if serverOK {
            lastResult = .serverOnly
        } else {
            lastResult = .failed("Нет связи ни с сервером, ни с Telegram")
        }
    }

    var resultMessage: String {
        switch lastResult {
        case .success(let n):              return "✅ SOS доставлен \(n) контакт(ам)"
        case .partialSuccess(let n, let t): return "⚠️ Доставлен \(n) из \(t) контактов"
        case .serverOnly:                  return "✅ SOS принят сервером"
        case .failed(let e):               return "❌ \(e)"
        case nil:                          return ""
        }
    }
}
