import Foundation

struct StorageEntry: Equatable {
    let id: String
    let byteSize: Int64
    let expiresAt: Date?
}

protocol StorageAdapter: AnyObject {
    func currentEntries() -> [StorageEntry]
    func removeEntries(ids: [String]) async
}

@MainActor
final class StorageManager {
    private let adapter: any StorageAdapter
    private var timer: Timer?

    init(adapter: any StorageAdapter) {
        self.adapter = adapter
    }

    deinit { timer?.invalidate() }

    func start(every interval: TimeInterval = 6 * 60 * 60) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = await self?.evictExpired()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func evictExpired() async -> [String] {
        let now = Date()
        let entries = adapter.currentEntries()
        let expiredIds = entries.compactMap { entry -> String? in
            if let exp = entry.expiresAt, exp <= now { return entry.id }
            return nil
        }
        if !expiredIds.isEmpty {
            await adapter.removeEntries(ids: expiredIds)
        }
        return expiredIds
    }

    func currentUsageBytes() async -> Int64 {
        adapter.currentEntries().reduce(0) { $0 + $1.byteSize }
    }
}

final class MemoryStorageAdapter: StorageAdapter {
    var snapshot: [StorageEntry] = []

    func currentEntries() -> [StorageEntry] { snapshot }
    func removeEntries(ids: [String]) async {
        snapshot.removeAll { ids.contains($0.id) }
    }
}
