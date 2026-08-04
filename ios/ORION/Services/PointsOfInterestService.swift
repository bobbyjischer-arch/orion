import Foundation
import CoreLocation
import Combine

/// Управление привычными точками интереса и детект приближения к ним.
///
/// Логика «направляешься туда?»: когда пользователь на ходу входит во
/// внешнее кольцо точки (approachRadius), но ещё не внутри неё, система
/// один раз задаёт вопрос. Повторно спросит только после того, как он
/// покинет внешнее кольцо (сброс состояния).
@MainActor
final class PointsOfInterestService: ObservableObject {

    static let shared = PointsOfInterestService()

    @Published var points: [PointOfInterest] = []
    /// Точка, по которой сейчас задан вопрос «направляешься туда?» (для UI).
    @Published var pendingApproach: PointOfInterest?

    private let notif = NotificationService.shared

    /// id точек, по которым вопрос уже задан и ещё не сброшен.
    private var asked = Set<UUID>()

    private init() { load() }

    // MARK: - CRUD

    func add(_ poi: PointOfInterest) {
        points.append(poi)
        save()
    }

    func update(_ poi: PointOfInterest) {
        guard let idx = points.firstIndex(where: { $0.id == poi.id }) else { return }
        points[idx] = poi
        save()
    }

    func delete(_ poi: PointOfInterest) {
        points.removeAll { $0.id == poi.id }
        asked.remove(poi.id)
        if pendingApproach?.id == poi.id { pendingApproach = nil }
        save()
    }

    // MARK: - Детект приближения

    /// Ближайшая точка в радиусе её внешнего кольца (для контекста «мозга»).
    func nearest(to location: CLLocation) -> PointOfInterest? {
        points
            .map { ($0, location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
            .filter { $0.1 <= $0.0.approachRadius }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Вызывать на каждом обновлении локации (дёшево, без сети).
    /// Возвращает точку, к которой пользователь приближается (если есть).
    @discardableResult
    func evaluate(location: CLLocation, speed: Double?) -> PointOfInterest? {
        let moving = (speed ?? 0) > 0.5

        for poi in points {
            let center = CLLocation(latitude: poi.latitude, longitude: poi.longitude)
            let distance = location.distance(from: center)

            if distance > poi.approachRadius {
                // Вышел из внешнего кольца — разрешаем спросить снова в будущем.
                asked.remove(poi.id)
                if pendingApproach?.id == poi.id { pendingApproach = nil }
                continue
            }

            // Внутри внешнего кольца. Если уже на месте (внутри radius) —
            // это «прибытие», вопрос про намерение не нужен.
            let arrived = distance <= poi.radius

            if !arrived, moving, !asked.contains(poi.id) {
                asked.insert(poi.id)
                pendingApproach = poi
                notif.notifyApproachingPOI(name: poi.name, category: poi.category.rawValue)
                return poi
            }
        }
        return nil
    }

    /// Ответ пользователя на вопрос «направляешься туда?».
    func answerApproach(_ heading: Bool) {
        // Намерение учтено — просто убираем вопрос. Состояние asked
        // оставляем, чтобы не спрашивать повторно в этом же подходе.
        pendingApproach = nil
    }

    // MARK: - Persistence (App Group)

    private var fileURL: URL? {
        AppSettings.sharedFileURL("points_of_interest.json")
    }

    private func save() {
        guard let url = fileURL, let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: url)
    }

    private func load() {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([PointOfInterest].self, from: data) else { return }
        points = loaded
    }
}
