import Foundation
import CoreLocation

struct LocationPoint: Codable, Identifiable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let source: String
    /// Человекочитаемое название места. Обратный геокодинг делает клиент:
    /// у сервера для этого нет ни сети, ни права ходить в чужой геокодер.
    /// Опциональное — старые файлы истории без этого поля читаются как есть.
    var place: String?
    /// Чей это трек. Проставляется при отправке; в старой истории пусто.
    var deviceID: String?

    init(coordinate: CLLocationCoordinate2D, source: String = "ios_orion") {
        self.id        = UUID()
        self.latitude  = coordinate.latitude
        self.longitude = coordinate.longitude
        self.timestamp = Date()
        self.source    = source
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var serverPayload: [String: Any] {
        var body: [String: Any] = [
            "latitude": latitude, "longitude": longitude,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "source": source,
        ]
        if let place, !place.isEmpty { body["place"] = place }
        if let deviceID, !deviceID.isEmpty { body["device_id"] = deviceID }
        return body
    }

    /// Ключ дня `YYYY-MM-DD` — по нему история группируется и фильтруется.
    var dayKey: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: timestamp)
    }

    /// Час суток точки — для фильтра «с 9 до 18».
    var hourOfDay: Int {
        Calendar.current.component(.hour, from: timestamp)
    }

    var timeString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f.string(from: timestamp)
    }

    /// Что показать в списке истории: название места, если оно известно,
    /// иначе координаты — пустая строка выглядела бы как потерянная точка.
    var placeOrCoords: String {
        if let place, !place.isEmpty { return place }
        return formattedCoords
    }

    var mapsURL: URL {
        URL(string: "https://maps.google.com/?q=\(latitude),\(longitude)")!
    }

    var formattedCoords: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    var timeAgoString: String {
        let secs = Int(-timestamp.timeIntervalSinceNow)
        if secs < 60  { return "только что" }
        if secs < 3600 { return "\(secs/60) мин назад" }
        return "\(secs/3600) ч назад"
    }
}
