import Foundation
import CoreLocation

/// Offline queue manager for location points
@MainActor
final class OfflineQueueService: ObservableObject {

    static let shared = OfflineQueueService()

    @Published var queuedCount: Int = 0
    @Published var isSyncing: Bool = false
    @Published var lastSyncDate: Date?

    private var queue: [LocationPoint] = []
    private let maxQueueSize = 1000

    private init() {
        loadQueue()
    }

    // MARK: - Queue Management

    func enqueue(_ point: LocationPoint) {
        queue.append(point)
        if queue.count > maxQueueSize {
            queue.removeFirst()
        }
        queuedCount = queue.count
        saveQueue()
    }

    func syncAll(to serverURL: String, network: NetworkService) async -> (success: Int, failed: Int) {
        guard !queue.isEmpty, !isSyncing else {
            return (0, 0)
        }

        isSyncing = true
        defer { isSyncing = false }

        var successCount = 0
        var failedCount = 0

        let pointsToSync = queue
        var remainingQueue: [LocationPoint] = []

        for point in pointsToSync {
            let success = await network.sendLocation(point, to: serverURL)
            if success {
                successCount += 1
            } else {
                failedCount += 1
                remainingQueue.append(point)
            }
        }

        queue = remainingQueue
        queuedCount = queue.count
        saveQueue()

        if successCount > 0 {
            lastSyncDate = Date()
        }

        return (successCount, failedCount)
    }

    func clearQueue() {
        queue.removeAll()
        queuedCount = 0
        saveQueue()
    }

    // MARK: - Persistence

    private var queueURL: URL? {
        AppSettings.sharedFileURL("offline_queue.json")
    }

    private func saveQueue() {
        guard let url = queueURL,
              let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: url)
    }

    private func loadQueue() {
        guard let url = queueURL,
              let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([LocationPoint].self, from: data) else { return }
        queue = loaded
        queuedCount = queue.count
    }
}
