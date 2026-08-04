import Foundation
import CoreLocation
import Combine

@MainActor
final class LocationService: NSObject, ObservableObject {

    // MARK: - Published State
    @Published var currentLocation: CLLocation?
    @Published var authStatus: CLAuthorizationStatus = .notDetermined
    @Published var isTracking = false
    @Published var serverOnline = false
    @Published var locationHistory: [LocationPoint] = []
    @Published var errorMessage: String?
    @Published var powerMode: PowerMode = .balanced

    enum PowerMode: String, CaseIterable {
        case economy = "Экономия"
        case balanced = "Баланс"
        case accuracy = "Точность"
    }

    // MARK: - Dependencies
    private let manager   = CLLocationManager()
    private let network   = NetworkService()
    private let notif     = NotificationService.shared
    private let settings  = AppSettings.shared
    private let offlineQueue = OfflineQueueService.shared

    // MARK: - Private
    private var sendTimer:   Timer?
    private var healthTimer: Timer?
    private var wasServerOnline = false
    private var isStationary = false
    private var lastMovementTime = Date()

    /// Обратный геокодинг точек трека — см. `resolvePlace(for:)`.
    private let geocoder = CLGeocoder()
    private let geocodeMinMeters: CLLocationDistance = 150
    private var lastGeocodedAt = Date.distantPast
    private var lastGeocodedCoord: CLLocationCoordinate2D?
    private var lastPlaceName: String?

    // MARK: - Init

    override init() {
        super.init()
        manager.delegate                      = self
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        authStatus = manager.authorizationStatus
        loadHistory()
        updateAccuracyForPowerMode()
    }

    // MARK: - Power Mode Management

    func setPowerMode(_ mode: PowerMode) {
        powerMode = mode
        updateAccuracyForPowerMode()
    }

    private func updateAccuracyForPowerMode() {
        switch powerMode {
        case .economy:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 100
        case .balanced:
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = 50
        case .accuracy:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 30
        }
    }

    private func adaptAccuracyBasedOnMovement() {
        guard powerMode == .balanced else { return }

        let timeSinceMovement = Date().timeIntervalSince(lastMovementTime)

        if timeSinceMovement > 300 { // 5 minutes stationary
            if !isStationary {
                isStationary = true
                // Switch to significant location changes for battery saving
                manager.stopUpdatingLocation()
                manager.startMonitoringSignificantLocationChanges()
            }
        } else {
            if isStationary {
                isStationary = false
                // Resume normal tracking
                manager.stopMonitoringSignificantLocationChanges()
                manager.startUpdatingLocation()
            }
        }
    }

    // MARK: - Control

    func startTracking() {
        guard authStatus == .authorizedAlways || authStatus == .authorizedWhenInUse else {
            manager.requestAlwaysAuthorization()
            return
        }
        manager.startUpdatingLocation()
        isTracking = true
        settings.systemStatus = "tracking"
        SuspicionService.shared.begin()   // режим «Анализирую»
        scheduleSend()
        scheduleHealthCheck()
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        sendTimer?.invalidate();   sendTimer   = nil
        healthTimer?.invalidate(); healthTimer = nil
        isTracking = false
        isStationary = false
        settings.systemStatus = "online"
    }

    func requestPermission() { manager.requestAlwaysAuthorization() }

    // MARK: - Manual send

    func sendNow() {
        guard let loc = currentLocation else { return }
        let point = LocationPoint(coordinate: loc.coordinate, source: "ios_manual")
        Task { await sendPoint(point) }
    }

    // MARK: - Timers

    private func scheduleSend() {
        sendTimer?.invalidate()
        let interval = TimeInterval(settings.intervalMinutes * 60)
        sendTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.sendCurrentLocation() }
        }
        sendCurrentLocation()
    }

    private func scheduleHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.checkServerHealth() }
        }
        Task { await checkServerHealth() }
    }

    private func sendCurrentLocation() {
        guard let loc = currentLocation else { return }
        Task {
            var point = LocationPoint(coordinate: loc.coordinate, source: "ios_orion")
            point.deviceID = settings.deviceID
            point.place    = await resolvePlace(for: loc)
            await sendPoint(point)
        }
    }

    // MARK: - Названия мест

    /// Название места для точки трека.
    ///
    /// CLGeocoder жёстко ограничен по частоте — Apple режет примерно раз в
    /// минуту и на превышении просто возвращает ошибку. Поэтому ходим в него
    /// только когда человек реально сместился больше чем на `geocodeMinMeters`
    /// и не чаще раза в минуту, а между запросами переиспользуем прошлое
    /// название: точки, снятые в одном дворе, и так относятся к одному месту.
    private func resolvePlace(for location: CLLocation) async -> String? {
        if let last = lastGeocodedCoord {
            let moved = location.distance(from: CLLocation(latitude: last.latitude,
                                                           longitude: last.longitude))
            if moved < geocodeMinMeters, Date().timeIntervalSince(lastGeocodedAt) < 60 {
                return lastPlaceName
            }
        }
        guard let mark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return lastPlaceName          // лимит геокодера или нет сети — не беда
        }
        // Улица с домом + город: этого хватает, чтобы узнать место в списке,
        // и не столько, чтобы список стало невозможно читать.
        var parts: [String] = []
        for part in [mark.name ?? mark.thoroughfare, mark.locality] {
            if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) }
        }
        let label = parts.joined(separator: ", ")
        lastGeocodedAt    = Date()
        lastGeocodedCoord = location.coordinate
        lastPlaceName     = label.isEmpty ? nil : label
        return lastPlaceName
    }

    private func sendPoint(_ point: LocationPoint) async {
        // Историю и последнюю точку храним ВСЕГДА (для карты и анализа),
        // независимо от доступности сервера.
        locationHistory.append(point)
        if locationHistory.count > Self.maxHistoryPoints { locationHistory.removeFirst() }
        saveHistory()
        settings.lastLatitude     = point.latitude
        settings.lastLongitude    = point.longitude
        settings.lastLocationDate = point.timestamp

        let ok = await network.sendLocation(point, to: settings.serverURL)
        if ok {
            settings.totalPointsSent += 1
            errorMessage = nil

            // Try to sync offline queue if we're back online
            if offlineQueue.queuedCount > 0 {
                Task {
                    let result = await offlineQueue.syncAll(to: settings.serverURL, network: network)
                    if result.success > 0 {
                        print("Synced \(result.success) offline points")
                    }
                }
            }
        } else {
            // Сервер недоступен — точка в офлайн-очередь на досылку
            offlineQueue.enqueue(point)
            errorMessage = "Нет связи с сервером (\(offlineQueue.queuedCount) в очереди)"
        }

        // «Мозг»: оценка подозрений НЕЗАВИСИМО от сервера — iOS ходит
        // в OpenRouter напрямую. Внутри evaluate — троттлинг.
        if let loc = currentLocation {
            let hist = locationHistory
            // Память кормим КАЖДОЙ точкой, а не раз в 10 минут: dwell меряется
            // временем между наблюдениями, и на редких вызовах он был бы враньём.
            // Это чистая арифметика — ни сети, ни геокодинга.
            SuspicionService.shared.observe(location: loc, speed: loc.speed)
            Task { await SuspicionService.shared.evaluate(location: loc, speed: loc.speed, history: hist) }
        }
    }

    private func checkServerHealth() async {
        let alive = await network.checkHealth(settings.serverURL)
        serverOnline = alive
        settings.serverReachable = alive

        if wasServerOnline && !alive {
            notif.notifyServerDown()
        } else if !wasServerOnline && alive {
            notif.notifyServerRestored()
        }
        wasServerOnline = alive
    }

    // MARK: - History persistence

    private var historyURL: URL? {
        AppSettings.sharedFileURL("location_history.json")
    }

    /// Сколько точек держим локально. Было 200 — при точке раз в 5 минут это
    /// меньше суток, а историю смотрят по датам за недели. 2000 точек — это
    /// около недели непрерывной записи и всё ещё меньше мегабайта JSON.
    static let maxHistoryPoints = 2000

    private func saveHistory() {
        guard let url = historyURL,
              let data = try? JSONEncoder().encode(Array(locationHistory.suffix(Self.maxHistoryPoints)))
        else { return }
        try? data.write(to: url)
    }

    private func loadHistory() {
        guard let url = historyURL,
              let data = try? Data(contentsOf: url),
              let points = try? JSONDecoder().decode([LocationPoint].self, from: data) else { return }
        locationHistory = points
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.currentLocation = locations.last

            // Detect movement for adaptive accuracy
            if let location = locations.last, location.speed > 0.5 { // Moving faster than 0.5 m/s
                self.lastMovementTime = Date()
            }

            // Детект приближения к точкам интереса (локально, без сети)
            if let location = locations.last {
                PointsOfInterestService.shared.evaluate(location: location, speed: location.speed)
            }

            self.adaptAccuracyBasedOnMovement()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedAlways { self.startTracking() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.errorMessage = "GPS: \(error.localizedDescription)" }
    }
}
