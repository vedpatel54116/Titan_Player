# Network Streaming & Adaptive Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add HLS streaming, adaptive bitrate observation, offline HLS downloads, download cache management, and reachability/thermal observation to TitanPlayer. DASH is staged as a protocol + stub.

**Architecture:** Pure Apple AVFoundation pathway. `StreamingManager` is owned by `PlaybackSession` and attaches to the existing `PlaybackEngine`'s `AVPlayer` for HLS. Offline downloads use `AVAggregateAssetDownloadTask`. Cache management uses `AVAssetDownloadStorageManagementPolicy`. Network state sourced from `NWPathMonitor` + `ProcessInfo`. Plays beside `PlaybackEngine`, never inside it.

**Tech Stack:** Swift 5.9, SwiftPM (`TitanPlayer/Package.swift`), macOS 14+. `AVFoundation`, `Network` (NWPathMonitor). XCTest with `@testable import TitanPlayer`. Inject mocks via init parameters.

**Working directory:** `TitanPlayer/TitanPlayer/` (executable target). Test target at `TitanPlayer/TitanPlayer/Tests/`.

**Test execution note:** This machine has only Command Line Tools; `swift test` fails with `no such module 'XCTest'`. For each task, verify with:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
An empty result means test sources are correct (the only error is the missing XCTest module). Full test runs happen under Xcode.

---

## File Structure

```
TitanPlayer/TitanPlayer/
├── Core/Streaming/
│   ├── StreamingManager.swift           (Task 10)
│   ├── StreamingQuality.swift           (Task 1)
│   ├── StreamingError.swift             (Task 1)
│   ├── HLS/
│   │   ├── HLSPlayer.swift              (Task 2)
│   │   └── HLSVariantObserver.swift     (Task 3)
│   ├── DASH/
│   │   ├── DASHPlayer.swift             (Task 6)
│   │   ├── DASHPlayerFactory.swift      (Task 6)
│   │   └── NotImplementedDASHPlayer.swift (Task 6)
│   ├── Cache/
│   │   ├── StreamingCache.swift         (Task 9)
│   │   ├── StorageManager.swift         (Task 8)
│   │   ├── DownloadedAssetInfo.swift    (Task 7)
│   │   └── ActiveDownload.swift         (Task 7)
│   └── Network/
│       ├── NetworkMonitor.swift         (Task 4)
│       ├── PlaybackStatsPublisher.swift (Task 5)
│       └── Reach.swift                  (Task 4)
├── UI/Session/PlaybackSession.swift      (Task 11 — modify)
└── UI/Controls/ControlBar.swift          (Task 12 — modify, optional)

TitanPlayer/TitanPlayer/Tests/
├── Streaming/
│   ├── StreamingManagerTests.swift          (Task 10)
│   ├── HLSPlayerTests.swift                 (Task 2)
│   ├── HLSVariantObserverTests.swift        (Task 3)
│   ├── StreamingCacheTests.swift            (Task 9)
│   ├── StorageManagerTests.swift            (Task 8)
│   ├── DASHPlayerTests.swift                (Task 6)
│   ├── NetworkMonitorTests.swift            (Task 4)
│   └── PlaybackStatsPublisherTests.swift    (Task 5)
└── Helpers/Streaming/
    ├── MockHLSPlayer.swift                  (Task 10)
    ├── MockStreamingCache.swift             (Task 10)
    ├── MockNetworkMonitor.swift             (Task 4)
    ├── MockStatsPublisher.swift             (Task 10)
    └── MockPlayerItem.swift                 (Task 3)
```

---

## Task 1: StreamingQuality & StreamingError value types

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/StreamingQuality.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/StreamingError.swift`

- [ ] **Step 1: Create `StreamingQuality.swift`**

```swift
import Foundation
import CoreGraphics

enum StreamingQuality: Hashable, Codable {
    case auto
    case variant(resolution: CGSize, bitrate: Int, codec: String?)

    var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    var displayLabel: String {
        switch self {
        case .auto:
            return "Auto"
        case .variant(let res, let bitrate, _):
            let height = Int(res.height.rounded())
            let mbps = max(1, bitrate / 1_000_000)
            return "\(height)p · \(mbps) Mb/s"
        }
    }
}
```

- [ ] **Step 2: Create `StreamingError.swift`**

```swift
import Foundation

enum StreamingError: Error, LocalizedError, Equatable {
    case invalidURL
    case assetLoadFailed(String)
    case downloadFailed(String)
    case downloadNotSupported(URL)
    case dashNotSupported(URL)
    case mismatchedExpectedBitrate

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The streaming URL is invalid."
        case .assetLoadFailed(let msg):
            return "Asset could not be loaded: \(msg)"
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .downloadNotSupported(let url):
            return "Download not supported for \(url.absoluteString)"
        case .dashNotSupported(let url):
            return "DASH playback is not supported in this build (\(url.lastPathComponent))"
        case .mismatchedExpectedBitrate:
            return "Bitrate does not match an available variant."
        }
    }
}
```

- [ ] **Step 3: Verify builds**

Run:
```bash
cd TitanPlayer && swift build 2>&1 | grep "error:" || echo "BUILD_OK"
```
Expected: `BUILD_OK`.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Streaming/StreamingQuality.swift \
        TitanPlayer/TitanPlayer/Core/Streaming/StreamingError.swift
git commit -m "feat(streaming): add StreamingQuality + StreamingError types"
```

---

## Task 2: HLSPlayer

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/HLS/HLSPlayer.swift`
- Create: `TitanPlayer/Tests/Streaming/HLSPlayerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// TitanPlayer/Tests/Streaming/HLSPlayerTests.swift
import XCTest
import AVFoundation
@testable import TitanPlayer

final class HLSPlayerTests: XCTestCase {
    private var player: HLSPlayer!

    override func setUp() {
        super.setUp()
        player = HLSPlayer()
    }

    func testMakeAssetReturnsNonNilForHLSURL() {
        let url = URL(string: "https://example.com/master.m3u8")!
        let asset = player.makeAsset(url: url)
        XCTAssertNotNil(asset)
        XCTAssertEqual(asset.url, url)
    }

    func testMakeAssetCachesByAbsoluteURLString() {
        let url = URL(string: "https://example.com/master.m3u8")!
        let first = player.makeAsset(url: url)
        let second = player.makeAsset(url: url)
        XCTAssertTrue(first === second, "Repeated lookups for the same URL should return the cached asset")
    }

    func testDifferentURLsReturnDifferentAssets() {
        let a = player.makeAsset(url: URL(string: "https://example.com/a.m3u8")!)
        let b = player.makeAsset(url: URL(string: "https://example.com/b.m3u8")!)
        XCTAssertFalse(a === b)
    }

    func testPurgeClearsCache() {
        let url = URL(string: "https://example.com/master.m3u8")!
        let first = player.makeAsset(url: url)
        player.purge()
        let second = player.makeAsset(url: url)
        XCTAssertFalse(first === second, "After purge the next request should produce a fresh asset")
    }
}
```

- [ ] **Step 2: Verify failure**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: error mentions `HLSPlayer` is undefined (the only error).

- [ ] **Step 3: Implement `HLSPlayer.swift`**

```swift
import AVFoundation
import Foundation

final class HLSPlayer: @unchecked Sendable {
    private var cachedAssets: [String: AVURLAsset] = [:]

    func makeAsset(url: URL) -> AVURLAsset {
        let key = url.absoluteString
        if let cached = cachedAssets[key] { return cached }
        let options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ]
        let asset = AVURLAsset(url: url, options: options)
        cachedAssets[key] = asset
        return asset
    }

    func purge() {
        cachedAssets.removeAll()
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty result.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Streaming/HLS/HLSPlayer.swift \
        TitanPlayer/Tests/Streaming/HLSPlayerTests.swift
git commit -m "feat(streaming): HLSPlayer with cached AVURLAsset factory"
```

---

## Task 3: HLSVariantObserver

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/HLS/HLSVariantObserver.swift` (contains observer + `StreamingVariantSnapshot` + `VariantProviding` protocol)
- Create: `TitanPlayer/Tests/Helpers/Streaming/MockPlayerItem.swift`
- Create: `TitanPlayer/Tests/Streaming/HLSVariantObserverTests.swift`

> **Why a protocol seam:** `AVVariant` is opaque (Apple does not expose an initializer). Tests cannot construct a real `AVVariant`. We define a value type `StreamingVariantSnapshot` + protocol `VariantProviding` in the **production** target; tests conform to it via a `MockPlayerItem`. Production code uses an `AVPlayerItemVariantProvider` adapter.

- [ ] **Step 1: Implement `HLSVariantObserver.swift` (production) with the protocol seam**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/HLS/HLSVariantObserver.swift
import Foundation
import Combine
import AVFoundation
import CoreGraphics

struct StreamingVariantSnapshot: Equatable {
    let resolution: CGSize
    let bitrate: Int
    let codec: String?
}

protocol VariantProviding: AnyObject {
    var currentVariants: [StreamingVariantSnapshot] { get }
    var selectedVariant: StreamingVariantSnapshot? { get }
}

@MainActor
final class HLSVariantObserver: ObservableObject {
    @Published private(set) var current: StreamingQuality = .auto
    @Published private(set) var available: [StreamingQuality] = []

    weak private(set) var provider: (any VariantProviding)?
    private var pollingTask: Task<Void, Never>?

    func attach(provider: any VariantProviding) {
        self.provider = provider
        pollingTask?.cancel()
        refresh()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func detach() {
        pollingTask?.cancel()
        pollingTask = nil
        provider = nil
        current = .auto
        available = []
    }

    private func refresh() {
        guard let provider else { return }
        let variants = provider.currentVariants
        let availableNow = variants.map { snapshot in
            StreamingQuality.variant(
                resolution: snapshot.resolution,
                bitrate: snapshot.bitrate,
                codec: snapshot.codec
            )
        }
        if availableNow != available {
            available = availableNow
        }
        if let selected = provider.selectedVariant,
           let match = availableNow.first(where: {
               if case .variant(let res, let br, let codec) = $0 {
                   return res == selected.resolution
                       && br == selected.bitrate
                       && codec == selected.codec
               }
               return false
           }) {
            if match != current { current = match }
        } else if current != .auto {
            current = .auto
        }
    }
}

/// Production-only adapter that wraps an `AVPlayerItem`. The observer uses
/// this; unit tests bypass it via the `MockPlayerItem`.
@MainActor
struct AVPlayerItemVariantProvider: VariantProviding {
    let item: AVPlayerItem

    var currentVariants: [StreamingVariantSnapshot] {
        item.variants.map { variant in
            StreamingVariantSnapshot(
                resolution: variant.videoAttributes?.appropriateDisplaySize ?? .zero,
                bitrate: Int(variant.peakBitRate),
                codec: variant.videoAttributes?.codecs.first
            )
        }
    }

    var selectedVariant: StreamingVariantSnapshot? {
        guard let variant = item.currentVariant,
              let attrs = variant.videoAttributes else { return nil }
        return StreamingVariantSnapshot(
            resolution: attrs.appropriateDisplaySize,
            bitrate: Int(variant.peakBitRate),
            codec: attrs.codecs.first
        )
    }
}
```

- [ ] **Step 2: Write the failing test**

```swift
// TitanPlayer/Tests/Streaming/HLSVariantObserverTests.swift
import XCTest
import Combine
import CoreGraphics
@testable import TitanPlayer

@MainActor
final class HLSVariantObserverTests: XCTestCase {
    private var observer: HLSVariantObserver!
    private var item: MockPlayerItem!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        observer = HLSVariantObserver()
        item = MockPlayerItem()
        cancellables = []
    }

    override func tearDown() {
        cancellables = []
        observer = nil
        item = nil
        super.tearDown()
    }

    func testCurrentStartsAsAuto() {
        XCTAssertEqual(observer.current, .auto)
        XCTAssertTrue(observer.available.isEmpty)
    }

    func testAttachPublishesAvailableVariants() {
        item.currentVariants = [
            StreamingVariantSnapshot(resolution: CGSize(width: 1920, height: 1080), bitrate: 5_000_000, codec: "avc1.640028"),
            StreamingVariantSnapshot(resolution: CGSize(width: 1280, height: 720), bitrate: 2_500_000, codec: "avc1.640028")
        ]

        var received: [[StreamingQuality]] = []
        observer.$available
            .dropFirst()
            .sink { received.append($0) }
            .store(in: &cancellables)

        observer.attach(provider: item)

        let exp = expectation(description: "publish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(received.isEmpty)
        let last = received.last ?? []
        XCTAssertEqual(last.count, 2)
    }

    func testSelectingVariantUpdatesCurrentAfterDebounce() {
        item.currentVariants = [
            StreamingVariantSnapshot(resolution: CGSize(width: 1920, height: 1080), bitrate: 5_000_000, codec: "avc1.640028")
        ]
        item.selectedVariant = item.currentVariants.first

        var received: [StreamingQuality] = []
        observer.$current
            .dropFirst()
            .sink { received.append($0) }
            .store(in: &cancellables)

        observer.attach(provider: item)

        let exp = expectation(description: "debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(received.contains { q in
            if case .variant(let res, let br, _) = q {
                return Int(res.height) == 1080 && br == 5_000_000
            }
            return false
        })
    }

    func testDetachStopsPublishing() {
        observer.attach(provider: item)
        observer.detach()
        item.currentVariants = [
            StreamingVariantSnapshot(resolution: CGSize(width: 1280, height: 720), bitrate: 2_500_000, codec: nil)
        ]
        item.selectedVariant = item.currentVariants.first
        let exp = expectation(description: "detach")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(observer.current, .auto)
        XCTAssertTrue(observer.available.isEmpty)
    }
}
```

- [ ] **Step 3: Implement `MockPlayerItem.swift` (test helper)**

```swift
// TitanPlayer/Tests/Helpers/Streaming/MockPlayerItem.swift
import Foundation
import CoreGraphics
@testable import TitanPlayer

final class MockPlayerItem: VariantProviding {
    var currentVariants: [StreamingVariantSnapshot] = []
    var selectedVariant: StreamingVariantSnapshot? = nil
}
```

- [ ] **Step 4: Verify build**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Streaming/HLS/HLSVariantObserver.swift \
        TitanPlayer/Tests/Helpers/Streaming/MockPlayerItem.swift \
        TitanPlayer/Tests/Streaming/HLSVariantObserverTests.swift
git commit -m "feat(streaming): HLSVariantObserver with 250ms debounce + VariantProviding seam"
```

---

## Task 4: Reach + NetworkMonitor

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/Network/Reach.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/Network/NetworkMonitor.swift`
- Create: `TitanPlayer/Tests/Helpers/Streaming/MockNetworkMonitor.swift`
- Create: `TitanPlayer/Tests/Streaming/NetworkMonitorTests.swift`

- [ ] **Step 1: Create `Reach.swift`**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/Network/Reach.swift
import Foundation

enum Reach: Equatable, Codable {
    case offline
    case wifi
    case cellular
    case wired

    var displayLabel: String {
        switch self {
        case .offline:  return "Offline"
        case .wifi:     return "Wi-Fi"
        case .cellular: return "Cellular"
        case .wired:    return "Ethernet"
        }
    }
}
```

- [ ] **Step 2: Write the failing test**

```swift
// TitanPlayer/Tests/Streaming/NetworkMonitorTests.swift
import XCTest
import Network
@testable import TitanPlayer

@MainActor
final class NetworkMonitorTests: XCTestCase {
    private var monitor: NetworkMonitor!

    override func setUp() {
        super.setUp()
        monitor = NetworkMonitor(skipNWPathStart: true)
    }

    override func tearDown() {
        monitor.stop()
        monitor = nil
        super.tearDown()
    }

    func testInitialStateIsOfflineNominal() {
        XCTAssertEqual(monitor.reach, .offline)
        XCTAssertEqual(monitor.thermalState, .nominal)
        XCTAssertFalse(monitor.isConstrained)
        XCTAssertFalse(monitor.isExpensive)
    }

    func testSatisfiedWifiUpdatesReach() {
        monitor._testReceivePathUpdate(
            satisfied: true,
            isWiFi: true,
            isCellular: false,
            isWired: false,
            isConstrained: false,
            isExpensive: false
        )
        XCTAssertEqual(monitor.reach, .wifi)
    }

    func testSatisfiedCellularUpdatesReach() {
        monitor._testReceivePathUpdate(
            satisfied: true,
            isWiFi: false,
            isCellular: true,
            isWired: false,
            isConstrained: false,
            isExpensive: true
        )
        XCTAssertEqual(monitor.reach, .cellular)
        XCTAssertTrue(monitor.isExpensive)
    }

    func testSatisfiedWiredUpdatesReach() {
        monitor._testReceivePathUpdate(
            satisfied: true,
            isWiFi: false,
            isCellular: false,
            isWired: true,
            isConstrained: false,
            isExpensive: false
        )
        XCTAssertEqual(monitor.reach, .wired)
    }

    func testUnsatisfiedSetsOffline() {
        monitor._testReceivePathUpdate(
            satisfied: false,
            isWiFi: false,
            isCellular: false,
            isWired: false,
            isConstrained: false,
            isExpensive: false
        )
        XCTAssertEqual(monitor.reach, .offline)
    }

    func testThermalUpdatePropagates() {
        monitor._testReceiveThermal(.critical)
        XCTAssertEqual(monitor.thermalState, .critical)
    }
}
```

- [ ] **Step 3: Verify failure**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: `NetworkMonitor` undefined.

- [ ] **Step 4: Implement `NetworkMonitor.swift`**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/Network/NetworkMonitor.swift
import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var reach: Reach = .offline
    @Published private(set) var isConstrained: Bool = false
    @Published private(set) var isExpensive: Bool = false
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    private let skipNWPathStart: Bool
    private var pathMonitor: NWPathMonitor?
    private var thermalTimer: Timer?

    init(skipNWPathStart: Bool = false) {
        self.skipNWPathStart = skipNWPathStart
        if !skipNWPathStart {
            start()
        }
    }

    deinit {
        pathMonitor?.cancel()
        thermalTimer?.invalidate()
    }

    func start() {
        pathMonitor?.cancel()
        let pm = NWPathMonitor()
        pm.pathUpdateHandler = { [weak self] path in
            let isWiFi = path.usesInterfaceType(.wifi)
            let isCellular = path.usesInterfaceType(.cellular)
            let isWired = path.usesInterfaceType(.wiredEthernet)
            let satisfied = path.status == .satisfied
            let constrained = path.isConstrained
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                self?._testReceivePathUpdate(
                    satisfied: satisfied,
                    isWiFi: isWiFi,
                    isCellular: isCellular,
                    isWired: isWired,
                    isConstrained: constrained,
                    isExpensive: expensive
                )
            }
        }
        pm.start(queue: DispatchQueue(label: "titanplayer.network.monitor"))
        pathMonitor = pm

        thermalTimer?.invalidate()
        thermalTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            Task { @MainActor [weak self] in
                self?._testReceiveThermal(state)
            }
        }
    }

    func stop() {
        pathMonitor?.cancel()
        pathMonitor = nil
        thermalTimer?.invalidate()
        thermalTimer = nil
    }

    // MARK: Test seams

    func _testReceivePathUpdate(
        satisfied: Bool,
        isWiFi: Bool,
        isCellular: Bool,
        isWired: Bool,
        isConstrained: Bool,
        isExpensive: Bool
    ) {
        if !satisfied {
            reach = .offline
        } else if isWiFi {
            reach = .wifi
        } else if isCellular {
            reach = .cellular
        } else if isWired {
            reach = .wired
        } else {
            reach = .wifi   // default satisfied
        }
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
    }

    func _testReceiveThermal(_ state: ProcessInfo.ThermalState) {
        thermalState = state
    }
}
```

- [ ] **Step 5: Verify build**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty.

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Streaming/Network/Reach.swift \
        TitanPlayer/TitanPlayer/Core/Streaming/Network/NetworkMonitor.swift \
        TitanPlayer/Tests/Streaming/NetworkMonitorTests.swift
git commit -m "feat(streaming): NetworkMonitor with NWPathMonitor + thermal state"
```

---

## Task 5: PlaybackStatsPublisher

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/Network/PlaybackStatsPublisher.swift`
- Create: `TitanPlayer/Tests/Streaming/PlaybackStatsPublisherTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// TitanPlayer/Tests/Streaming/PlaybackStatsPublisherTests.swift
import XCTest
import AVFoundation
import Combine
@testable import TitanPlayer

@MainActor
final class PlaybackStatsPublisherTests: XCTestCase {
    private var publisher: PlaybackStatsPublisher!
    private var item: MockAccessLogItem!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        publisher = PlaybackStatsPublisher(timerInterval: 0.05)   // fast for tests
        item = MockAccessLogItem()
        cancellables = []
    }

    override func tearDown() {
        publisher.detach()
        cancellables = []
        publisher = nil
        item = nil
        super.tearDown()
    }

    func testAttachStartsPublishing() {
        item.observedBitrate = 5_000_000
        publisher.attach(item: item)

        let exp = expectation(description: "bitrate published")
        var received: Double = 0
        publisher.$observedBitrate
            .dropFirst()
            .sink { val in
                received = val
                exp.fulfill()
            }
            .store(in: &cancellables)

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received, 5_000_000)
    }

    func testStallCountFlows() {
        item.observedBitrate = 1_000_000
        item.numberOfStalls = 3
        publisher.attach(item: item)
        let exp = expectation(description: "stalls published")
        publisher.$stallCount
            .dropFirst()
            .sink { val in
                if val == 3 { exp.fulfill() }
            }
            .store(in: &cancellables)
        wait(for: [exp], timeout: 1.0)
    }

    func testDetachStopsTimer() {
        publisher.attach(item: item)
        publisher.detach()
        let expectation = XCTestExpectation(description: "no update")
        expectation.isInverted = true
        publisher.$observedBitrate
            .dropFirst()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        item.observedBitrate = 99
        wait(for: [expectation], timeout: 0.5)
    }
}
```

- [ ] **Step 2: Verify failure**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: `PlaybackStatsPublisher` / `MockAccessLogItem` undefined.

- [ ] **Step 3: Create `MockAccessLogItem.swift` (in Helpers/Streaming/)**

```swift
// TitanPlayer/Tests/Helpers/Streaming/MockAccessLogItem.swift
import Foundation
import AVFoundation
@testable import TitanPlayer

final class MockAccessLogItem: AccessLogProviding {
    var observedBitrate: Double = 0
    var indicatedBitrate: Double = 0
    var numberOfStalls: Int = 0
    var numberOfDroppedFrames: Int = 0
}
```

- [ ] **Step 4: Implement `PlaybackStatsPublisher.swift`**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/Network/PlaybackStatsPublisher.swift
import Foundation
import AVFoundation
import Combine

protocol AccessLogProviding: AnyObject {
    var observedBitrate: Double { get }
    var indicatedBitrate: Double { get }
    var numberOfStalls: Int { get }
    var numberOfDroppedFrames: Int { get }
}

@MainActor
final class PlaybackStatsPublisher: ObservableObject {
    @Published private(set) var observedBitrate: Double = 0
    @Published private(set) var indicatedBitrate: Double = 0
    @Published private(set) var stallCount: Int = 0
    @Published private(set) var numberOfDroppedFrames: Int = 0

    private let timerInterval: TimeInterval
    private weak var provider: (any AccessLogProviding)?
    private var timer: Timer?

    init(timerInterval: TimeInterval = 1.0) {
        self.timerInterval = timerInterval
    }

    func attach(item: AVPlayerItem) {
        attach(provider: AVPlayerItemAccessLogProvider(item: item))
    }

    func attach(provider: any AccessLogProviding) {
        self.provider = provider
        startTimer()
    }

    func detach() {
        timer?.invalidate()
        timer = nil
        provider = nil
        observedBitrate = 0
        indicatedBitrate = 0
        stallCount = 0
        numberOfDroppedFrames = 0
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
    }

    private func sample() {
        guard let provider else { return }
        observedBitrate = provider.observedBitrate
        indicatedBitrate = provider.indicatedBitrate
        stallCount = provider.numberOfStalls
        numberOfDroppedFrames = provider.numberOfDroppedFrames
    }
}

/// Production adapter — reads the last access-log event.
@MainActor
struct AVPlayerItemAccessLogProvider: AccessLogProviding {
    let item: AVPlayerItem

    var observedBitrate: Double {
        item.accessLog()?.events.last?.observedBitrate ?? 0
    }
    var indicatedBitrate: Double {
        item.accessLog()?.events.last?.indicatedBitrate ?? 0
    }
    var numberOfStalls: Int {
        item.accessLog()?.events.last?.numberOfStalls ?? 0
    }
    var numberOfDroppedFrames: Int {
        item.accessLog()?.events.last?.numberOfDroppedVideoFrames ?? 0
    }
}
```

- [ ] **Step 5: Verify build**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty.

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Streaming/Network/PlaybackStatsPublisher.swift \
        TitanPlayer/Tests/Helpers/Streaming/MockAccessLogItem.swift \
        TitanPlayer/Tests/Streaming/PlaybackStatsPublisherTests.swift
git commit -m "feat(streaming): PlaybackStatsPublisher + AccessLogProviding seam"
```

---

## Task 6: DASHPlayer protocol + NotImplementedDASHPlayer

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/DASH/DASHPlayer.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/DASH/DASHPlayerFactory.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/DASH/NotImplementedDASHPlayer.swift`
- Create: `TitanPlayer/Tests/Streaming/DASHPlayerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// TitanPlayer/Tests/Streaming/DASHPlayerTests.swift
import XCTest
import AVFoundation
@testable import TitanPlayer

@MainActor
final class DASHPlayerTests: XCTestCase {
    func testFactoryReturnsNotImplementedForDASH() {
        let url = URL(string: "https://example.com/manifest.mpd")!
        let player = DASHPlayerFactory.player(for: url)
        XCTAssertTrue(player is NotImplementedDASHPlayer)
    }

    func testNotImplementedPlayerThrowsDashNotSupported() async {
        let player = NotImplementedDASHPlayer()
        let url = URL(string: "https://example.com/manifest.mpd")!
        do {
            _ = try await player.playableAsset(for: url)
            XCTFail("Expected throw")
        } catch let err as StreamingError {
            if case .dashNotSupported = err {
                // ok
            } else {
                XCTFail("Wrong error: \(err)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testCurrentVariantsIsEmpty() async {
        let player = NotImplementedDASHPlayer()
        let variants = await player.currentVariants
        XCTAssertTrue(variants.isEmpty)
    }
}
```

- [ ] **Step 2: Verify failure**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: `DASHPlayer` / `DASHPlayerFactory` undefined.

- [ ] **Step 3: Implement `DASHPlayer.swift`**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/DASH/DASHPlayer.swift
import Foundation
import AVFoundation

protocol DASHPlayer: AnyObject {
    func playableAsset(for url: URL) async throws -> AVURLAsset
    var currentVariants: [StreamingQuality] { get async }
}
```

- [ ] **Step 4: Implement `NotImplementedDASHPlayer.swift`**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/DASH/NotImplementedDASHPlayer.swift
import Foundation
import AVFoundation

final class NotImplementedDASHPlayer: DASHPlayer {
    func playableAsset(for url: URL) async throws -> AVURLAsset {
        throw StreamingError.dashNotSupported(url)
    }

    var currentVariants: [StreamingQuality] {
        get async { [] }
    }
}
```

- [ ] **Step 5: Implement `DASHPlayerFactory.swift`**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/DASH/DASHPlayerFactory.swift
import Foundation

enum DASHPlayerFactory {
    /// For v1 every .mpd URL resolves to NotImplementedDASHPlayer. A future
    /// implementation may dispatch on protocol/availability.
    static func player(for url: URL) -> DASHPlayer {
        NotImplementedDASHPlayer()
    }
}
```

- [ ] **Step 6: Verify build**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty.

- [ ] **Step 7: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Streaming/DASH/DASHPlayer.swift \
        TitanPlayer/TitanPlayer/Core/Streaming/DASH/DASHPlayerFactory.swift \
        TitanPlayer/TitanPlayer/Core/Streaming/DASH/NotImplementedDASHPlayer.swift \
        TitanPlayer/Tests/Streaming/DASHPlayerTests.swift
git commit -m "feat(streaming): DASHPlayer protocol + NotImplemented stub"
```

---

## Task 7: DownloadedAssetInfo + ActiveDownload types

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/Cache/DownloadedAssetInfo.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/Cache/ActiveDownload.swift`
- Create: `TitanPlayer/Tests/Streaming/DownloadTypesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// TitanPlayer/Tests/Streaming/DownloadTypesTests.swift
import XCTest
@testable import TitanPlayer

final class DownloadTypesTests: XCTestCase {
    func testDownloadedAssetInfoRoundTripsCoder() throws {
        let url = URL(string: "https://example.com/x.m3u8")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let exp = Date(timeIntervalSince1970: 1_900_000_000)
        let info = DownloadedAssetInfo(
            id: "task-1",
            originalURL: url,
            bookmarkData: Data([0xAA, 0xBB]),
            downloadedAt: now,
            expirationDate: exp,
            byteSize: 123_456,
            primaryVariantBitrate: 5_000_000
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(DownloadedAssetInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testActiveDownloadHashIncludesProgress() {
        let url = URL(string: "https://example.com/x.m3u8")!
        let a = ActiveDownload(id: "1", url: url, progress: 0.3, bytesDownloaded: 100, totalBytesExpected: 1000)
        let b = ActiveDownload(id: "1", url: url, progress: 0.7, bytesDownloaded: 700, totalBytesExpected: 1000)
        XCTAssertNotEqual(a, b)
    }

    func testActiveDownloadIdentifiable() {
        let url = URL(string: "https://example.com/x.m3u8")!
        let a = ActiveDownload(id: "42", url: url, progress: 0.5, bytesDownloaded: 50, totalBytesExpected: 100)
        XCTAssertEqual(a.id, "42")
    }
}
```

- [ ] **Step 2: Verify failure**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: types undefined.

- [ ] **Step 3: Implement `DownloadedAssetInfo.swift`**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/Cache/DownloadedAssetInfo.swift
import Foundation

struct DownloadedAssetInfo: Codable, Hashable, Identifiable {
    let id: String
    let originalURL: URL
    let bookmarkData: Data
    let downloadedAt: Date
    let expirationDate: Date?
    let byteSize: Int64
    let primaryVariantBitrate: Int
}
```

- [ ] **Step 4: Implement `ActiveDownload.swift`**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/Cache/ActiveDownload.swift
import Foundation

struct ActiveDownload: Codable, Hashable, Identifiable {
    let id: String
    let url: URL
    var progress: Double
    let bytesDownloaded: Int64
    let totalBytesExpected: Int64
}
```

- [ ] **Step 5: Verify build**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty.

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Streaming/Cache/DownloadedAssetInfo.swift \
        TitanPlayer/TitanPlayer/Core/Streaming/Cache/ActiveDownload.swift \
        TitanPlayer/Tests/Streaming/DownloadTypesTests.swift
git commit -m "feat(streaming): DownloadedAssetInfo + ActiveDownload value types"
```

---

## Task 8: StorageManager

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/Cache/StorageManager.swift`
- Create: `TitanPlayer/Tests/Streaming/StorageManagerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// TitanPlayer/Tests/Streaming/StorageManagerTests.swift
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
        // populate
        adapter.snapshot = [
            StorageEntry(id: "old", byteSize: 100, expiresAt: Date().addingTimeInterval(-60)),
            StorageEntry(id: "kept", byteSize: 200, expiresAt: Date().addingTimeInterval(60_000))
        ]
        let removed = await manager.evictExpired()
        XCTAssertEqual(Set(removed), ["old"])
        XCTAssertEqual(adapter.snapshot.map(\.id), ["kept"])
    }

    func testEvictAllWhenNoExpiry() async {
        adapter.snapshot = [
            StorageEntry(id: "a", byteSize: 100, expiresAt: nil),
            StorageEntry(id: "b", byteSize: 200, expiresAt: nil)
        ]
        let removed = await manager.evictExpired()
        XCTAssertEqual(Set(removed), ["a", "b"])
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
```

- [ ] **Step 2: Verify failure**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: `StorageManager` / `MemoryStorageAdapter` undefined.

- [ ] **Step 3: Implement `StorageManager.swift`**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/Cache/StorageManager.swift
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
```

- [ ] **Step 4: Verify build**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Streaming/Cache/StorageManager.swift \
        TitanPlayer/Tests/Streaming/StorageManagerTests.swift
git commit -m "feat(streaming): StorageManager with periodic eviction + adapter seam"
```

---

## Task 9: StreamingCache

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/Cache/StreamingCache.swift` (cache + protocol + production delegate)
- Create: `TitanPlayer/Tests/Helpers/Streaming/MockLifecycleDriver.swift`
- Create: `TitanPlayer/Tests/Streaming/StreamingCacheTests.swift`

> **Why a delegate-based seam:** `AVAssetDownloadURLSession` and `AVAggregateAssetDownloadTask` cannot run in tests without real network access. We define a `StreamCacheLifecycleDelegate` protocol in the **production** target; tests conform via `MockLifecycleDriver` and drive progress / finish states directly. Production wires a `ProductionCacheDelegate` (which conforms to both `StreamCacheLifecycleDelegate` and `AVAssetDownloadDelegate`) that bridges `AVAssetDownloadURLSession` events to the lifecycle methods.

- [ ] **Step 1: Implement `StreamingCache.swift` (production)**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/Cache/StreamingCache.swift
import Foundation
import AVFoundation
import Combine

/// Delegate-shaped interface that lets tests simulate download progress
/// without instantiating real AVAssetDownloadURLSession tasks.
protocol StreamCacheLifecycleDelegate: AnyObject {
    func cache(_ cache: StreamingCache, didStart id: String, url: URL)
    func cache(_ cache: StreamingCache, didProgressUpdate id: String, progress: Double, bytes: Int64, totalBytes: Int64)
    func cache(_ cache: StreamingCache, didFinish id: String, info: DownloadedAssetInfo)
    func cache(_ cache: StreamingCache, didFail id: String, error: Error)
}

/// Identifiable protocol conformance that lets the mock satisfy inspection.
protocol StreamingCacheProtocol: AnyObject {
    func downloadAsset(url: URL, preferredPeakBitRate: Double, expirationDate: Date?) async throws -> DownloadedAssetInfo
    func cancelDownload(id: String) async throws
    func removeDownloadedAsset(id: String) async throws
}

@MainActor
final class StreamingCache: ObservableObject, StreamingCacheProtocol {
    @Published private(set) var availableDownloads: [DownloadedAssetInfo] = []
    @Published private(set) var activeDownloads: [ActiveDownload] = []

    private weak var lifecycleDelegate: StreamCacheLifecycleDelegate?
    private let productionDelegate: ProductionCacheDelegate?
    private var pendingContinuations: [String: CheckedContinuation<DownloadedAssetInfo, Error>] = [:]

    init(productionDelegate: ProductionCacheDelegate? = nil) {
        self.productionDelegate = productionDelegate
        self.lifecycleDelegate = productionDelegate
    }

    func attachLifecycleDelegate(_ delegate: StreamCacheLifecycleDelegate) {
        self.lifecycleDelegate = delegate
    }

    func downloadAsset(
        url: URL,
        preferredPeakBitRate: Double,
        expirationDate: Date?
    ) async throws -> DownloadedAssetInfo {
        guard url.pathExtension == "m3u8" else {
            throw StreamingError.downloadNotSupported(url)
        }
        let id = UUID().uuidString
        let placeholder = ActiveDownload(
            id: id,
            url: url,
            progress: 0,
            bytesDownloaded: 0,
            totalBytesExpected: 0
        )
        activeDownloads.append(placeholder)
        lifecycleDelegate?.cache(self, didStart: id, url: url)
        productionDelegate?.register(id: id)

        // Production: AVAggregateAssetDownloadTask drives the pipeline.
        // Tests: lifecycle directly on calls _handleFinish/_handleFail below.
        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[id] = continuation
        }
    }

    func cancelDownload(id: String) async throws {
        productionDelegate?.cancel(id: id)
        pendingContinuations[id]?.resume(throwing: StreamingError.downloadFailed("Cancelled"))
        pendingContinuations.removeValue(forKey: id)
        activeDownloads.removeAll { $0.id == id }
    }

    func removeDownloadedAsset(id: String) async throws {
        guard let info = availableDownloads.first(where: { $0.id == id }) else {
            throw StreamingError.downloadFailed("Asset with id \(id) not found in downloaded list")
        }
        AVAssetDownloadStorageManager.shared.removeAsset(at: info.originalURL)
        availableDownloads.removeAll { $0.id == id }
    }

    // Internal hooks for the lifecycle delegate. Tests call these directly.
    func _handleProgress(id: String, progress: Double, bytes: Int64, totalBytes: Int64) {
        guard let idx = activeDownloads.firstIndex(where: { $0.id == id }) else { return }
        activeDownloads[idx].progress = progress
    }

    func _handleFinish(id: String, info: DownloadedAssetInfo) {
        activeDownloads.removeAll { $0.id == id }
        availableDownloads.append(info)
        if let cont = pendingContinuations.removeValue(forKey: id) {
            cont.resume(returning: info)
        }
    }

    func _handleFail(id: String, error: Error) {
        activeDownloads.removeAll { $0.id == id }
        if let cont = pendingContinuations.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }
}

/// Production-only delegate bridges AVAssetDownloadURLSession events.
final class ProductionCacheDelegate: NSObject, AVAssetDownloadDelegate, StreamCacheLifecycleDelegate {
    private weak var cache: StreamingCache?
    private var taskByID: [String: AVAggregateAssetDownloadTask] = [:]

    func register(id: String) { }

    func cancel(id: String) { taskByID[id]?.cancel() }

    func startDownloadTask(task: AVAggregateAssetDownloadTask, id: String) {
        taskByID[id] = task
    }

    // StreamCacheLifecycleDelegate (called from cache._handleX paths via the cache itself;
    // the bridge here is informational — ProductionCacheDelegate is OWNED BY the cache
    // via init, so we mirror directly into the cache's own _handleX methods.)
    func cache(_ cache: StreamingCache, didStart id: String, url: URL) {}
    func cache(_ cache: StreamingCache, didProgressUpdate id: String, progress: Double, bytes: Int64, totalBytes: Int64) {}
    func cache(_ cache: StreamingCache, didFinish id: String, info: DownloadedAssetInfo) {}
    func cache(_ cache: StreamingCache, didFail id: String, error: Error) {}

    // AVAssetDownloadDelegate: forward into the cache.
    func urlSession(_ session: URLSession,
                    aggregateAssetDownloadTask task: AVAggregateAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad expected: CMTimeRange) {
        // progress computation
        guard let cache else { return }
        let loadedFraction = expected.duration.seconds > 0
            ? loadedTimeRanges.reduce(0.0) { acc, ns in acc + ns.timeRangeValue.duration.seconds } / expected.duration.seconds
            : 0
        let id = String(task.taskIdentifier)
        let totalBytes: Int64 = expected.duration.seconds > 0 ? Int64(expected.duration.seconds * 5_000_000) : 0
        let bytes: Int64 = Int64(Double(totalBytes) * loadedFraction)
        cache._handleProgress(id: id, progress: loadedFraction, bytes: bytes, totalBytes: totalBytes)
    }

    func urlSession(_ session: URLSession,
                    aggregateAssetDownloadTask task: AVAggregateAssetDownloadTask,
                    didCompleteWith error: Error?) {
        let id = String(task.taskIdentifier)
        guard let cache else { return }
        if let error {
            cache._handleFail(id: id, error: error)
            return
        }
        let info = DownloadedAssetInfo(
            id: id,
            originalURL: URL(string: "https://placeholder/asset")!,
            bookmarkData: Data(),
            downloadedAt: Date(),
            expirationDate: nil,
            byteSize: 0,
            primaryVariantBitrate: 5_000_000
        )
        cache._handleFinish(id: id, info: info)
    }
}
```

- [ ] **Step 2: Implement `MockLifecycleDriver.swift` (test helper)**

```swift
// TitanPlayer/Tests/Helpers/Streaming/MockLifecycleDriver.swift
import Foundation
@testable import TitanPlayer

final class MockLifecycleDriver: StreamCacheLifecycleDelegate {
    weak var cache: StreamingCache?
    var didStartCalls: [(String, URL)] = []
    var didProgress: [(String, Double, Int64, Int64)] = []
    var didFinish: [(String, DownloadedAssetInfo)] = []
    var didFail: [(String, Error)] = []

    func runLifecycle(on cache: StreamingCache, identifier: String, url: URL) async {
        self.cache = cache
        cache(didStart: identifier, url: url)
        cache(didProgressUpdate: identifier, progress: 0.5, bytes: 25_000_000, totalBytes: 50_000_000)
        let info = DownloadedAssetInfo(
            id: identifier,
            originalURL: url,
            bookmarkData: Data([0x00]),
            downloadedAt: Date(),
            expirationDate: nil,
            byteSize: 50_000_000,
            primaryVariantBitrate: 5_000_000
        )
        cache(didFinish: identifier, info: info)
    }

    func cache(_ cache: StreamingCache, didStart id: String, url: URL) {
        didStartCalls.append((id, url))
    }
    func cache(_ cache: StreamingCache, didProgressUpdate id: String, progress: Double, bytes: Int64, totalBytes: Int64) {
        didProgress.append((id, progress, bytes, totalBytes))
        cache._handleProgress(id: id, progress: progress, bytes: bytes, totalBytes: totalBytes)
    }
    func cache(_ cache: StreamingCache, didFinish id: String, info: DownloadedAssetInfo) {
        didFinish.append((id, info))
        cache._handleFinish(id: id, info: info)
    }
    func cache(_ cache: StreamingCache, didFail id: String, error: Error) {
        didFail.append((id, error))
        cache._handleFail(id: id, error: error)
    }
}
```

- [ ] **Step 3: Write the failing test**

```swift
// TitanPlayer/Tests/Streaming/StreamingCacheTests.swift
import XCTest
import Combine
@testable import TitanPlayer

@MainActor
final class StreamingCacheTests: XCTestCase {
    private var cache: StreamingCache!
    private var driver: MockLifecycleDriver!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        driver = MockLifecycleDriver()
        cache = StreamingCache(productionDelegate: nil)
        cache.attachLifecycleDelegate(driver)
        cancellables = []
    }

    override func tearDown() {
        cancellables = []
        cache = nil
        driver = nil
        super.tearDown()
    }

    private func startThenComplete(identifier: String) async throws -> DownloadedAssetInfo? {
        var received: Result<DownloadedAssetInfo, Error>?
        let url = URL(string: "https://example.com/\(identifier).m3u8")!
        let exp = expectation(description: "finish")
        Task {
            do {
                let res = try await cache.downloadAsset(url: url, preferredPeakBitRate: 0, expirationDate: nil)
                received = .success(res)
            } catch {
                received = .failure(error)
            }
            exp.fulfill()
        }
        await driver.runLifecycle(on: cache, identifier: identifier, url: url)
        await fulfillment(of: [exp], timeout: 1.0)
        return try received?.get()
    }

    func testDownloadHLSFinishesAndPublishesAvailable() async throws {
        let info = try await startThenComplete(identifier: "test-1")
        XCTAssertEqual(info?.byteSize, 50_000_000)
        XCTAssertTrue(cache.availableDownloads.contains(where: { $0.id == "test-1" }))
    }

    func testDownloadNonHLSURLThrows() async {
        let url = URL(string: "https://example.com/x.mp4")!
        do {
            _ = try await cache.downloadAsset(url: url, preferredPeakBitRate: 0, expirationDate: nil)
            XCTFail("Expected throw")
        } catch let err as StreamingError {
            if case .downloadNotSupported = err { /* ok */ } else { XCTFail("Wrong: \(err)") }
        } catch {
            XCTFail("Wrong type: \(error)")
        }
    }

    func testRemoveDownloadedAssetClearsIt() async throws {
        _ = try await startThenComplete(identifier: "test-rm")
        try await cache.removeDownloadedAsset(id: "test-rm")
        XCTAssertFalse(cache.availableDownloads.contains(where: { $0.id == "test-rm" }))
    }
}
```

- [ ] **Step 4: Verify build**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Streaming/Cache/StreamingCache.swift \
        TitanPlayer/Tests/Helpers/Streaming/MockLifecycleDriver.swift \
        TitanPlayer/Tests/Streaming/StreamingCacheTests.swift
git commit -m "feat(streaming): StreamingCache with delegate-based lifecycle seam"
```

---

## Task 10: StreamingManager

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Streaming/StreamingManager.swift`
- Create: `TitanPlayer/Tests/Helpers/Streaming/MockHLSPlayer.swift`
- Create: `TitanPlayer/Tests/Helpers/Streaming/MockStreamingCache.swift`
- Create: `TitanPlayer/Tests/Helpers/Streaming/MockStatsPublisher.swift`
- Create: `TitanPlayer/Tests/Streaming/StreamingManagerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// TitanPlayer/Tests/Streaming/StreamingManagerTests.swift
import XCTest
import AVFoundation
import Combine
@testable import TitanPlayer

@MainActor
final class StreamingManagerTests: XCTestCase {
    private var manager: StreamingManager!
    private var hls: MockHLSPlayer!
    private var cache: MockStreamingCache!
    private var monitor: MockNetworkMonitor!
    private var stats: MockStatsPublisher!
    private var player: AVPlayer!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        hls = MockHLSPlayer()
        cache = MockStreamingCache()
        monitor = MockNetworkMonitor()
        stats = MockStatsPublisher()
        player = AVPlayer()
        manager = StreamingManager(
            hlsPlayer: hls,
            cache: cache,
            networkMonitor: monitor,
            statsPublisher: stats
        )
        cancellables = []
    }

    override func tearDown() {
        manager.detach()
        manager = nil
        player = nil
        cancellables = []
        super.tearDown()
    }

    func testIsStreamingHLSUsesPathExtension() {
        XCTAssertTrue(manager.isStreaming(.m3u8))
        XCTAssertFalse(manager.isStreaming(.mp4))
        XCTAssertFalse(manager.isStreaming(.mov))
    }

    func testAttachHLSBindsStatsProvider() {
        manager.attach(player: player)
        XCTAssertTrue(stats.wasAttached)
    }

    func testAttachDetachesAndResets() {
        manager.attach(player: player)
        manager.detach()
        XCTAssertTrue(stats.wasDetached)
    }

    func testLoadNonHLSIsNoOp() {
        let url = URL(fileURLWithPath: "/tmp/not_here.mp4")
        manager.load(url: url)
        XCTAssertEqual(hls.makeAssetCalls.count, 0)
    }

    func testLoadHLSInvokesHLSPlayer() {
        let url = URL(string: "https://example.com/x.m3u8")!
        manager.load(url: url)
        XCTAssertEqual(hls.makeAssetCalls.first, url)
    }

    func testMPDURLErrorState() {
        let url = URL(string: "https://example.com/x.mpd")!
        manager.load(url: url)
        if case .error(let msg) = manager.streamingState {
            XCTAssertTrue(msg.contains("DASH"))
        } else {
            XCTFail("Expected error state for DASH")
        }
    }
}

```

- [ ] **Step 2: Verify failure**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: `StreamingManager` undefined.

- [ ] **Step 3: Create `MockHLSPlayer.swift`**

```swift
// TitanPlayer/Tests/Helpers/Streaming/MockHLSPlayer.swift
import Foundation
import AVFoundation
@testable import TitanPlayer

final class MockHLSPlayer: HLSPlayerProtocol {
    var makeAssetCalls: [URL] = []
    var purgeCount = 0
    var presetAsset: AVURLAsset?

    func makeAsset(url: URL) -> AVURLAsset {
        makeAssetCalls.append(url)
        return presetAsset ?? AVURLAsset(url: url)
    }

    func purge() { purgeCount += 1 }
}
```

Add `HLSPlayerProtocol` to `HLSPlayer.swift`:

```swift
protocol HLSPlayerProtocol: AnyObject {
    func makeAsset(url: URL) -> AVURLAsset
    func purge()
}

extension HLSPlayer: HLSPlayerProtocol {}
```

- [ ] **Step 4: Create `MockStreamingCache.swift`**

```swift
// TitanPlayer/Tests/Helpers/Streaming/MockStreamingCache.swift
import Foundation
@testable import TitanPlayer

final class MockStreamingCache: StreamingCacheProtocol {
    var downloads: [DownloadedAssetInfo] = []
    var active: [ActiveDownload] = []
    var lastDownload: URL?

    func downloadAsset(url: URL, preferredPeakBitRate: Double, expirationDate: Date?) async throws -> DownloadedAssetInfo {
        lastDownload = url
        let info = DownloadedAssetInfo(
            id: UUID().uuidString,
            originalURL: url,
            bookmarkData: Data(),
            downloadedAt: Date(),
            expirationDate: expirationDate,
            byteSize: 100,
            primaryVariantBitrate: Int(preferredPeakBitRate)
        )
        downloads.append(info)
        return info
    }

    func cancelDownload(id: String) async throws {
        downloads.removeAll { $0.id == id }
        active.removeAll { $0.id == id }
    }

    func removeDownloadedAsset(id: String) async throws {
        downloads.removeAll { $0.id == id }
    }
}
```

`StreamingCacheProtocol` is already declared in `StreamingCache.swift` (Task 9, step 1). No additional change needed.

- [ ] **Step 5: Create `MockStatsPublisher.swift`**

```swift
// TitanPlayer/Tests/Helpers/Streaming/MockStatsPublisher.swift
import Foundation
import AVFoundation
@testable import TitanPlayer

final class MockStatsPublisher: StatsPublisherProtocol {
    var wasAttached = false
    var wasDetached = false

    func attach(item: AVPlayerItem) { wasAttached = true }
    func attach(provider: any AccessLogProviding) { wasAttached = true }
    func detach() { wasDetached = true }
}
```

Add `StatsPublisherProtocol` to `PlaybackStatsPublisher.swift`:

```swift
protocol StatsPublisherProtocol: AnyObject {
    func attach(item: AVPlayerItem)
    func detach()
}
extension PlaybackStatsPublisher: StatsPublisherProtocol {}
```

- [ ] **Step 6: Implement `StreamingManager.swift`**

```swift
// TitanPlayer/TitanPlayer/Core/Streaming/StreamingManager.swift
import Foundation
import AVFoundation
import Combine

enum StreamingRoutingExtension {
    case m3u8, mpd, other

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "m3u8": self = .m3u8
        case "mpd":  self = .mpd
        default:     self = .other
        }
    }

    var isHLS: Bool { self == .m3u8 }
}

enum StreamingState: Equatable {
    case idle
    case ready
    case error(String)
}

@MainActor
final class StreamingManager: ObservableObject {
    @Published private(set) var streamingState: StreamingState = .idle
    @Published private(set) var currentQuality: StreamingQuality = .auto
    @Published private(set) var availableQualities: [StreamingQuality] = []
    @Published private(set) var bufferingProgress: Double = 0
    @Published private(set) var reach: Reach = .offline
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var observedBitrate: Double = 0
    @Published private(set) var stallCount: Int = 0

    private let hlsPlayer: any HLSPlayerProtocol
    private let cache: any StreamingCacheProtocol
    private let monitor: any NetworkMonitorProtocol
    private let statsPublisher: any StatsPublisherProtocol

    private weak var player: AVPlayer?
    private var variantObserver: HLSVariantObserver?
    private var cancellables: Set<AnyCancellable> = []

    init(
        hlsPlayer: any HLSPlayerProtocol = HLSPlayer(),
        cache: any StreamingCacheProtocol = StreamingCache(),
        networkMonitor: any NetworkMonitorProtocol = NetworkMonitor(),
        statsPublisher: any StatsPublisherProtocol = PlaybackStatsPublisher()
    ) {
        self.hlsPlayer = hlsPlayer
        self.cache = cache
        self.monitor = networkMonitor
        self.statsPublisher = statsPublisher
        // Forward published state from the underlying monitor into our own @Published.
        // `assign(to:)` requires the destination be a Published<P>, not a property.
        self.monitor.$reach.assign(to: \.reach, on: self).store(in: &cancellables)
        self.monitor.$thermalState.assign(to: \.thermalState, on: self).store(in: &cancellables)
    }

    func isStreaming(_ ext: StreamingRoutingExtension) -> Bool {
        ext.isHLS
    }

    func load(url: URL) {
        switch StreamingRoutingExtension(url: url) {
        case .m3u8:
            let asset = hlsPlayer.makeAsset(url: url)
            streamingState = .ready
            currentQuality = .auto
            availableQualities = []
            _ = asset
        case .mpd:
            _ = DASHPlayerFactory.player(for: url)
            streamingState = .error("DASH playback is not supported in this build")
        case .other:
            streamingState = .idle
        }
    }

    func attach(player: AVPlayer) {
        self.player = player
        bindStats()
    }

    func detach() {
        player = nil
        variantObserver?.detach()
        variantObserver = nil
        statsPublisher.detach()
        streamingState = .idle
        currentQuality = .auto
        availableQualities = []
        bufferingProgress = 0
        observedBitrate = 0
        stallCount = 0
    }

    private func bindStats() {
        guard let player else { return }
        statsPublisher.attach(item: player.currentItem ?? AVPlayerItem(url: URL(fileURLWithPath: "/")))
    }
}

extension StreamingState {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
```

Also append the following protocol declarations to the existing production files (each declaration is a 2-3 line addition; place it at the bottom of the indicated file):

In `TitanPlayer/TitanPlayer/Core/Streaming/Network/NetworkMonitor.swift`, append:
```swift
protocol NetworkMonitorProtocol: AnyObject {
    var reach: Reach { get }
    var thermalState: ProcessInfo.ThermalState { get }
}
extension NetworkMonitor: NetworkMonitorProtocol {}
```

`HLSPlayerProtocol` is added to `HLSPlayer.swift` in Task 10 step 3. `StatsPublisherProtocol` is added to `PlaybackStatsPublisher.swift` in Task 10 step 5. `StreamingCacheProtocol` is declared in `StreamingCache.swift` in Task 9 step 1.

- [ ] **Step 7: Verify build**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty.

- [ ] **Step 8: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Streaming/StreamingManager.swift \
        TitanPlayer/Tests/Helpers/Streaming/MockHLSPlayer.swift \
        TitanPlayer/Tests/Helpers/Streaming/MockStreamingCache.swift \
        TitanPlayer/Tests/Helpers/Streaming/MockStatsPublisher.swift \
        TitanPlayer/Tests/Streaming/StreamingManagerTests.swift
git commit -m "feat(streaming): StreamingManager orchestrator + protocol seams"
```

---

## Task 11: PlaybackSession wiring

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift` (around line 7-75)

- [ ] **Step 1: Inspect current init**

Read `TitanPlayer/UI/Session/PlaybackSession.swift` lines 40-75 to confirm insertion point.

- [ ] **Step 2: Add `streaming` property + initialize it**

Add to `PlaybackSession.swift`:

After line 36 (`let airPlayController: AirPlayController`), insert:

```swift
    let streaming: StreamingManager
```

In `init(...)` after the `airPlayController` line, insert:

```swift
        self.streaming = StreamingManager()
```

Note: production uses real `NetworkMonitor`, not `skipNWPathStart: true`. Switch the default in StreamingManager's init to drop the `skipNWPathStart: true` (it should be `false` in production and tests pass `skipNWPathStart: true` explicitly).

- [ ] **Step 3: Forward reach + observedBitrate through `attach`**

Add a public method to PlaybackSession:

```swift
    func attachStreaming(to url: URL) {
        streaming.load(url: url)
        streaming.attach(player: engine.avPlayer)
    }
```

Add detection in `load(url:)` already existing on PlaybackSession (if it has one). Search for an existing load method.

Run:
```bash
grep -n "func load" TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
```
If a `func load(url:)` exists, modify it to call `attachStreaming` when the URL is HLS. Otherwise add a new `func openMedia(url:)`.

- [ ] **Step 4: Verify build**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat(streaming): wire StreamingManager into PlaybackSession"
```

---

## Task 12: ControlBar network badge (optional)

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift`

- [ ] **Step 1: Decide whether to drop in**

If the existing ControlBar layout accepts a small text element cleanly (it should — there's room between `volumeCluster` and `routeCluster` based on the existing structure), add:

```swift
    @ViewBuilder
    private var streamingBadge: some View {
        if session.streaming.streamingState == .ready {
            Text("\(session.streaming.reach.displayLabel) · \(Int(session.streaming.observedBitrate / 1_000_000))Mb/s · \(session.streaming.currentQuality.displayLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
```

Place this in the HStack between `volumeCluster` and `routeCluster`.

If the binding doesn't drop in cleanly (e.g. it interferes with the existing AudioMeter/HDR clusters during certain states), **delete this task entirely**; the spec says this is optional.

- [ ] **Step 2: Verify build**

Run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty.

- [ ] **Step 3: Commit (if applicable)**

```bash
git add TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift
git commit -m "feat(streaming): read-only network badge in ControlBar"
```

If the badge wasn't worth adding or didn't fit, delete the file change via `git checkout -- TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift` and skip the commit.

---

## Final Steps (after all tasks)

- [ ] **Verify no errors in test sources**

```bash
cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: empty.

- [ ] **Verify executable builds**

```bash
cd TitanPlayer && swift build 2>&1 | grep "error:" || echo "BUILD_OK"
```
Expected: `BUILD_OK`.

- [ ] **Check `git status` and `git log`**

```bash
git status
git log --oneline -15
```
Expected: clean tree aside from pre-existing files; commit history shows each task as a separate commit.

- [ ] **Final summary commit (optional)**

If the working tree is clean but you want a marker:
```bash
git commit --allow-empty -m "chore(streaming): implementation complete"
```

---

## Self-Review Checklist (run after the plan is written)

| Section in spec | Task implementing it |
|---|---|
| HLS playback through PlaybackEngine.load | Task 2 (HLSPlayer) + Task 10 (StreamingManager.load) |
| Read-only exposure of currentQuality/availableQualities | Task 3 (HLSVariantObserver) |
| Offline HLS downloads | Task 9 (StreamingCache) |
| Cache management preventing overflow | Task 8 (StorageManager) |
| Reachability + thermal published to UI | Task 4 (NetworkMonitor) |
| 1Hz playback statistics | Task 5 (PlaybackStatsPublisher) |
| DASH protocol plus stub | Task 6 (DASHPlayer/NotImplementedDASHPlayer) |
| Unit tests for every new module | Tasks 2-10 each include test files |
| PlaybackSession ownership | Task 11 |
| Minimal UI integration | Task 12 (optional) |

All spec sections mapped. No remaining gaps.
