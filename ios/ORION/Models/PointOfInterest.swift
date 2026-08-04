import Foundation
import CoreLocation

/// Привычная точка интереса пользователя (дом, зал, работа, школа…).
/// Система детектит приближение к ней и спрашивает «направляешься туда?»,
/// а также передаёт её имя «мозгу» как контекст анализа.
struct PointOfInterest: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var category: Category
    var latitude: Double
    var longitude: Double
    /// Радиус «прибытия» в метрах: внутри него считаем, что пользователь на месте.
    var radius: Double

    init(id: UUID = UUID(),
         name: String,
         category: Category = .other,
         latitude: Double,
         longitude: Double,
         radius: Double = 150) {
        self.id = id
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Внешнее кольцо: входя в него на ходу, считаем что пользователь
    /// «приближается» — и задаём вопрос.
    var approachRadius: Double { radius + 400 }

    enum Category: String, Codable, CaseIterable, Identifiable {
        case home   = "Дом"
        case gym    = "Зал"
        case work   = "Работа"
        case school = "Школа"
        case other  = "Другое"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home:   return "house.fill"
            case .gym:    return "dumbbell.fill"
            case .work:   return "briefcase.fill"
            case .school: return "graduationcap.fill"
            case .other:  return "mappin.circle.fill"
            }
        }

        /// Имя по умолчанию при создании точки этой категории.
        var defaultName: String { rawValue }
    }
}
