import XCTest
@testable import TitanPlayer

@MainActor
final class StorageManagerTests: XCTestCase {
    private var sandbox: URL!
    private var manager: StorageManager!
    private var adapter: MemoryStorageAdapter!

    override func setUp() {
        super.setUp()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("sm-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        adapter = MemoryStorageAdapter()
        manager = StorageManager(adapter: adapter)
    }

    override func tearDown() {
        manager.stop()
        try? FileManager.default.removeItem(at: sandbox)
        super.tearDown()
    }

    func testInitialUsageIsZero() async {
        let bytes = await manager.currentUsageBytes()
        XCTAssertEqual(bytes, 0)
    }

    func testEvictExpiredRemovesOnlyExpired() async {
        adapter.snapshot = [
            StorageEntry(id: "old", byteSize: 100, expiresAt: Date().addingTimeInterval(-60)),
            StorageEntry(id: "kept", byteSize: 200, expiresAt: Date().addingTimeInterval(60_000))
        ]
        let removed = await manager.evictExpired()
        XCTAssertEqual(Set(removed), ["old"])
        XCTAssertEqual(adapter.snapshot.map(\.id), ["kept"])
    }

    func testEvictKeepsEntriesWithoutExpiry() async {
        adapter.snapshot = [
            StorageEntry(id: "a", byteSize: 100, expiresAt: nil),
            StorageEntry(id: "b", byteSize: 200, expiresAt: nil)
        ]
        let removed = await manager.evictExpired()
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(adapter.snapshot.map(\.id), ["a", "b"])
    }

    func testUsageSumsSnapshot() async {
        adapter.snapshot = [
            StorageEntry(id: "a", byteSize: 100, expiresAt: nil),
            StorageEntry(id: "b", byteSize: 250, expiresAt: nil)
        ]
        let bytes = await manager.currentUsageBytes()
        XCTAssertEqual(bytes, 350)
    }
}
