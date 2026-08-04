import Foundation

final class NetworkService {

    private let session: URLSession
    private let pinnedCertificates: [Data] = [] // Add your server's certificate data here

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 8
        cfg.timeoutIntervalForResource = 15

        let delegate = SSLPinningDelegate(pinnedCertificates: pinnedCertificates)
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    func sendLocation(_ point: LocationPoint, to serverURL: String) async -> Bool {
        // Если задан общий секрет каскадного шифрования — шлём зашифрованно.
        if let secret = cascadeSecret() {
            return await postSecure(payload: point.serverPayload, kind: "location",
                                    serverURL: serverURL, secret: secret)
        }
        guard let url = URL(string: "\(serverURL)/location/update") else { return false }
        return await post(url: url, body: point.serverPayload, authorized: true)
    }

    /// Общий секрет каскадного шифрования из Keychain (nil → шифрование выключено).
    private func cascadeSecret() -> Data? {
        guard let s = try? KeychainService.shared.retrieve(for: .cascadeSecret),
              !s.isEmpty else { return nil }
        return s.data(using: .utf8)
    }

    /// Ключ доступа к защищённым эндпоинтам core (X-Orion-Key).
    private func apiKey() -> String? {
        try? KeychainService.shared.retrieve(for: .serverAuthToken)
    }

    /// Зашифровать payload каскадом и отправить на /secure/ingest.
    private func postSecure(payload: [String: Any], kind: String,
                            serverURL: String, secret: Data) async -> Bool {
        guard let url = URL(string: "\(serverURL)/secure/ingest"),
              let raw = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        let token = CascadeCrypto.encryptBase64(raw, secret: secret)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey() { req.setValue(key, forHTTPHeaderField: "X-Orion-Key") }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: ["kind": kind, "payload": token])
            let (_, r) = try await session.data(for: req)
            return (200..<300).contains((r as? HTTPURLResponse)?.statusCode ?? 0)
        } catch { return false }
    }

    func checkHealth(_ serverURL: String) async -> Bool {
        guard let url = URL(string: "\(serverURL)/api/status") else { return false }
        do {
            let (_, r) = try await session.data(from: url)
            return (r as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    func sendSOS(lat: Double, lon: Double, serverURL: String, mediaURLs: [String] = []) async -> Bool {
        guard let url = URL(string: "\(serverURL)/sos/trigger") else { return false }
        return await post(url: url, body: [
            "latitude":  lat,
            "longitude": lon,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source":    "ios_manual",
            "media":     mediaURLs
        ], authorized: true)
    }

    /// Резервный канал: напрямую через Telegram Bot API
    func sendSOSViaTelegram(
        botToken: String,
        contacts: [SOSContact],
        lat: Double, lon: Double,
        lastSeen: Date?,
        silent: Bool = false
    ) async -> Int {
        guard !botToken.isEmpty, !contacts.isEmpty else { return 0 }

        let mapsLink = "https://maps.google.com/?q=\(lat),\(lon)"
        let timeStr  = lastSeen.map {
            RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())
        } ?? "только что"
        let prefix = silent ? "🔇" : "🆘"
        let text = "\(prefix) *SOS от O.R.I.O.N.*\n\n📍 [Местоположение](\(mapsLink))\n🕐 Последний раз: \(timeStr)\n\n_Автоматическое уведомление безопасности._"

        var count = 0
        await withTaskGroup(of: Bool.self) { group in
            for c in contacts {
                group.addTask {
                    await self.telegramSend(token: botToken, chatID: c.telegramChatID, text: text)
                }
            }
            for await ok in group { if ok { count += 1 } }
        }
        return count
    }

    // MARK: - Private

    /// `authorized` добавляет X-Orion-Key: он нужен всем эндпоинтам core,
    /// закрытым require_api_key (/location/update, /sos/trigger, /secure/ingest).
    /// Для Telegram API ключ, наоборот, слать нельзя.
    private func post(url: URL, body: [String: Any], authorized: Bool = false) async -> Bool {
        var req        = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized, let key = apiKey() { req.setValue(key, forHTTPHeaderField: "X-Orion-Key") }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, r) = try await session.data(for: req)
            return (200..<300).contains((r as? HTTPURLResponse)?.statusCode ?? 0)
        } catch { return false }
    }

    private func telegramSend(token: String, chatID: String, text: String) async -> Bool {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return false }
        return await post(url: url, body: ["chat_id": chatID, "text": text, "parse_mode": "Markdown"])
    }
}

// MARK: - SSL Pinning Delegate

class SSLPinningDelegate: NSObject, URLSessionDelegate {

    private let pinnedCertificates: [Data]

    init(pinnedCertificates: [Data]) {
        self.pinnedCertificates = pinnedCertificates
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Нет запиненных сертификатов → отдаём проверку системе (стандартная
        // валидация цепочки доверия ОС). НЕ доверяем вслепую — это была дыра
        // (принимался любой сертификат, что слабее дефолта и уязвимо к MITM).
        if pinnedCertificates.isEmpty {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Validate certificate chain
        var secResult = SecTrustResultType.invalid
        let status = SecTrustEvaluate(serverTrust, &secResult)

        guard status == errSecSuccess else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Get server certificate
        guard let serverCertificate = SecTrustGetCertificateAtIndex(serverTrust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let serverCertificateData = SecCertificateCopyData(serverCertificate) as Data

        // Check if server certificate matches any pinned certificate
        for pinnedCertificate in pinnedCertificates {
            if serverCertificateData == pinnedCertificate {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        // Certificate not pinned
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
