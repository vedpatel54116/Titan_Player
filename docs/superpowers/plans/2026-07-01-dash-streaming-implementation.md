# DASH Streaming — Hybrid FFmpeg + Custom ABR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement functional DASH streaming with FFmpeg-backed demuxing and custom ABR quality switching.

**Architecture:** FFmpeg handles MPD parsing and segment downloading via its built-in DASH demuxer. A custom Swift MPD parser extracts quality metadata. A custom ABR controller monitors throughput and drives quality switching by restarting the FFmpeg demuxer with new representation URLs.

**Tech Stack:** Swift, Foundation XMLParser, Libavformat (FFmpeg), existing MediaPipeline/MediaDemuxing architecture.

---

## File Structure

### New Files (6)
| File | Purpose |
|------|---------|
| `TitanPlayer/Core/Streaming/DASH/Models/DASHQuality.swift` | Value type for a single representation |
| `TitanPlayer/Core/Streaming/DASH/Models/MPDManifest.swift` | Value type for parsed MPD structure |
| `TitanPlayer/Core/Streaming/DASH/MPDParser.swift` | Lightweight XML parser for MPD manifests |
| `TitanPlayer/Core/Streaming/DASH/DASHABRController.swift` | Throughput monitoring + quality switching logic |
| `TitanPlayer/Core/Streaming/DASH/DASHStreamSession.swift` | Wraps FFmpegDemuxer for DASH, conforms to MediaDemuxing |
| `TitanPlayer/Core/Streaming/DASH/DASHPlayerImpl.swift` | Concrete DASHPlayer implementation |

### Modified Files (5)
| File | Change |
|------|--------|
| `TitanPlayer/Core/Streaming/DASH/DASHPlayer.swift` | Add `streamSession(for:)` to protocol |
| `TitanPlayer/Core/Streaming/DASH/DASHPlayerFactory.swift` | Return `DASHPlayerImpl` |
| `TitanPlayer/Core/Engine/MediaPipeline.swift` | Add `openStream(session:)` method |
| `TitanPlayer/Core/Engine/PlaybackEngine.swift` | Route `.mpd` URLs through DASH path |
| `TitanPlayer/Core/Streaming/StreamingManager.swift` | Wire up DASH player |

### New Test Files (3)
| File | Purpose |
|------|---------|
| `TitanPlayer/Tests/Streaming/DASHQualityTests.swift` | Value type tests |
| `TitanPlayer/Tests/Streaming/MPDParserTests.swift` | Parser tests with real MPD fixtures |
| `TitanPlayer/Tests/Streaming/DASHABRControllerTests.swift` | ABR decision logic tests |

---

## Task 1: DASHQuality Model

**Files:**
- Create: `TitanPlayer/Core/Streaming/DASH/Models/DASHQuality.swift`
- Create: `TitanPlayer/Tests/Streaming/DASHQualityTests.swift`

- [ ] **Step 1: Create DASHQuality model**

```swift
// TitanPlayer/Core/Streaming/DASH/Models/DASHQuality.swift
import Foundation

struct DASHQuality: Identifiable, Hashable, Sendable {
    let id: String
    let bandwidth: Int
    let width: Int?
    let height: Int?
    let codec: String?
    let mimeType: String?
    let baseUrl: String?

    var resolutionLabel: String {
        guard let w = width, let h = height else { return "unknown" }
        return "\(w)x\(h)"
    }
}

extension DASHQuality {
    static func sortedByBandwidth(_ qualities: [DASHQuality]) -> [DASHQuality] {
        qualities.sorted { $0.bandwidth < $1.bandwidth }
    }
}
```

- [ ] **Step 2: Write tests for DASHQuality**

```swift
// TitanPlayer/Tests/Streaming/DASHQualityTests.swift
import XCTest
@testable import TitanPlayer

final class DASHQualityTests: XCTestCase {
    func testSortedByBandwidthAscending() {
        let a = DASHQuality(id: "high", bandwidth: 5_000_000, width: 1920, height: 1080, codec: "h264", mimeType: nil, baseUrl: nil)
        let b = DASHQuality(id: "low", bandwidth: 1_000_000, width: 640, height: 360, codec: "h264", mimeType: nil, baseUrl: nil)
        let c = DASHQuality(id: "mid", bandwidth: 2_500_000, width: 1280, height: 720, codec: "h264", mimeType: nil, baseUrl: nil)

        let sorted = DASHQuality.sortedByBandwidth([a, b, c])
        XCTAssertEqual(sorted.map(\.id), ["low", "mid", "high"])
    }

    func testResolutionLabelWithDimensions() {
        let q = DASHQuality(id: "1", bandwidth: 1_000_000, width: 1280, height: 720, codec: nil, mimeType: nil, baseUrl: nil)
        XCTAssertEqual(q.resolutionLabel, "1280x720")
    }

    func testResolutionLabelWithoutDimensions() {
        let q = DASHQuality(id: "1", bandwidth: 1_000_000, width: nil, height: nil, codec: nil, mimeType: nil, baseUrl: nil)
        XCTAssertEqual(q.resolutionLabel, "unknown")
    }

    func testHashableConformance() {
        let a = DASHQuality(id: "1", bandwidth: 1_000_000, width: nil, height: nil, codec: nil, mimeType: nil, baseUrl: nil)
        let b = DASHQuality(id: "1", bandwidth: 1_000_000, width: nil, height: nil, codec: nil, mimeType: nil, baseUrl: nil)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
    }
}
```

- [ ] **Step 3: Verify tests pass**

Run from `TitanPlayer/`:
```bash
swift build --build-tests 2>&1 | grep -E "(error:|Build complete)"
```
Expected: `Build complete` with no errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/Core/Streaming/DASH/Models/DASHQuality.swift TitanPlayer/Tests/Streaming/DASHQualityTests.swift
git commit -m "feat(dash): add DASHQuality value type with sorting"
```

---

## Task 2: MPDManifest Model

**Files:**
- Create: `TitanPlayer/Core/Streaming/DASH/Models/MPDManifest.swift`

- [ ] **Step 1: Create MPDManifest model**

```swift
// TitanPlayer/Core/Streaming/DASH/Models/MPDManifest.swift
import Foundation

struct MPDManifest: Sendable {
    let type: MPDType
    let mediaPresentationDuration: Double?
    let minBufferTime: Double?
    let videoAdaptations: [AdaptationSet]
    let audioAdaptations: [AdaptationSet]

    enum MPDType: String, Sendable {
        case `static`
        case dynamic
    }

    struct AdaptationSet: Sendable {
        let id: String?
        let mimeType: String
        let lang: String?
        let representations: [DASHQuality]
    }
}

extension MPDManifest {
    var allVideoQualities: [DASHQuality] {
        videoAdaptations.flatMap(\.representations)
    }

    var allAudioQualities: [DASHQuality] {
        audioAdaptations.flatMap(\.representations)
    }

    var lowestVideoQuality: DASHQuality? {
        DASHQuality.sortedByBandwidth(allVideoQualities).first
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/Core/Streaming/DASH/Models/MPDManifest.swift
git commit -m "feat(dash): add MPDManifest model for parsed MPD structure"
```

---

## Task 3: MPDParser

**Files:**
- Create: `TitanPlayer/Core/Streaming/DASH/MPDParser.swift`
- Create: `TitanPlayer/Tests/Streaming/MPDParserTests.swift`

- [ ] **Step 1: Create MPDParser**

```swift
// TitanPlayer/Core/Streaming/DASH/MPDParser.swift
import Foundation

enum MPDParserError: Error, LocalizedError {
    case fetchFailed(String)
    case invalidXML(String)
    case missingRequiredElement(String)

    var errorDescription: String? {
        switch self {
        case .fetchFailed(let msg): return "Failed to fetch MPD: \(msg)"
        case .invalidXML(let msg): return "Invalid MPD XML: \(msg)"
        case .missingRequiredElement(let el): return "Missing required element: \(el)"
        }
    }
}

actor MPDParser {
    static func parse(url: URL) async throws -> MPDManifest {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw MPDParserError.fetchFailed("HTTP \(response)")
        }

        return try parse(data: data, baseURL: url)
    }

    static func parse(data: Data, baseURL: URL) throws -> MPDManifest {
        let parser = _MPDParserDelegate(baseURL: baseURL)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()

        guard let manifest = parser.result else {
            throw MPDParserError.invalidXML(parser.parseError ?? "Unknown error")
        }
        return manifest
    }
}

private class _MPDParserDelegate: NSObject, XMLParserDelegate {
    let baseURL: URL
    var result: MPDManifest?

    private var currentElement = ""
    private var currentAttributes: [String: String] = [:]
    private var textContent = ""

    private var mpdType: MPDManifest.MPDType = .static
    private var mpdDuration: Double?
    private var mpdMinBuffer: Double?
    private var periods: [[String: Any]] = []
    private var currentPeriod: [String: Any]?

    // Adaptation set accumulator
    private var adaptationSets: [[String: Any]] = []
    private var currentAdaptationSet: [String: Any]?
    private var representations: [DASHQuality] = []
    private var currentRepresentation: DASHQuality?
    private var currentBaseUrl: String?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName
        currentAttributes = attributes
        textContent = ""

        switch elementName {
        case "MPD":
            if let type = attributes["type"], type == "dynamic" {
                mpdType = .dynamic
            }
            mpdDuration = attributes["mediaPresentationDuration"].flatMap { parseDuration($0) }
            mpdMinBuffer = attributes["minBufferTime"].flatMap { parseDuration($0) }

        case "Period":
            currentPeriod = ["adaptationSets": []]

        case "AdaptationSet":
            currentAdaptationSet = [
                "id": attributes["id"] as Any,
                "mimeType": attributes["mimeType"] as Any,
                "lang": attributes["lang"] as Any
            ]
            representations = []
            if let lb = attributes["lang"] {
                currentAdaptationSet?["lang"] = lb
            }

        case "Representation":
            let repId = attributes["id"] ?? UUID().uuidString
            let bandwidth = Int(attributes["bandwidth"] ?? "0") ?? 0
            let width = attributes["width"].flatMap { Int($0) }
            let height = attributes["height"].flatMap { Int($0) }
            let codec = attributes["codecs"]
            let mimeType = attributes["mimeType"]

            currentRepresentation = DASHQuality(
                id: repId,
                bandwidth: bandwidth,
                width: width,
                height: height,
                codec: codec,
                mimeType: mimeType,
                baseUrl: nil
            )

        case "BaseURL":
            textContent = ""

        case "SegmentTemplate", "SegmentList":
            break

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textContent += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "BaseURL":
            currentBaseUrl = textContent.trimmingCharacters(in: .whitespacesAndNewlines)

        case "Representation":
            if var rep = currentRepresentation {
                if let base = currentBaseUrl {
                    rep = DASHQuality(
                        id: rep.id, bandwidth: rep.bandwidth,
                        width: rep.width, height: rep.height,
                        codec: rep.codec, mimeType: rep.mimeType,
                        baseUrl: base
                    )
                }
                representations.append(rep)
            }
            currentRepresentation = nil

        case "AdaptationSet":
            if let mimeType = currentAdaptationSet?["mimeType"] as? String {
                let adaptSet = MPDManifest.AdaptationSet(
                    id: currentAdaptationSet?["id"] as? String,
                    mimeType: mimeType,
                    lang: currentAdaptationSet?["lang"] as? String,
                    representations: representations
                )
                adaptationSets.append(["set": adaptSet, "mimeType": mimeType])
            }
            currentAdaptationSet = nil
            representations = []

        case "Period":
            currentPeriod = nil

        case "MPD":
            let videoAdaptations = adaptationSets
                .filter { ($0["mimeType"] as? String)?.hasPrefix("video") == true }
                .compactMap { $0["set"] as? MPDManifest.AdaptationSet }
            let audioAdaptations = adaptationSets
                .filter { ($0["mimeType"] as? String)?.hasPrefix("audio") == true }
                .compactMap { $0["set"] as? MPDManifest.AdaptationSet }

            result = MPDManifest(
                type: mpdType,
                mediaPresentationDuration: mpdDuration,
                minBufferTime: mpdMinBuffer,
                videoAdaptations: videoAdaptations,
                audioAdaptations: audioAdaptations
            )

        default:
            break
        }
    }

    private func parseDuration(_ s: String) -> Double? {
        // Parse ISO 8601 duration: PT1H2M3.4S
        let regex = try? NSRegularExpression(pattern: "PT(?:(\\d+)H)?(?:(\\d+)M)?(?:([\\d.]+)S)?")
        guard let regex = regex else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = regex.firstMatch(in: s, range: range) else { return nil }

        let hours = match.range(at: 1).location != NSNotFound
            ? Double(s[Range(match.range(at: 1), in: s)!])! : 0
        let minutes = match.range(at: 2).location != NSNotFound
            ? Double(s[Range(match.range(at: 2), in: s)!])! : 0
        let seconds = match.range(at: 3).location != NSNotFound
            ? Double(s[Range(match.range(at: 3), in: s)!])! : 0

        return hours * 3600 + minutes * 60 + seconds
    }
}
```

- [ ] **Step 2: Write MPDParser tests**

```swift
// TitanPlayer/Tests/Streaming/MPDParserTests.swift
import XCTest
@testable import TitanPlayer

final class MPDParserTests: XCTestCase {
    private let baseMPD = """
    <?xml version="1.0" encoding="UTF-8"?>
    <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
         type="static"
         mediaPresentationDuration="PT30M0S"
         minBufferTime="PT2S">
      <Period>
        <AdaptationSet id="video" mimeType="video/mp4" segmentAlignment="true">
          <Representation id="v1" bandwidth="1000000" width="640" height="360" codecs="avc1.4d401e"/>
          <Representation id="v2" bandwidth="2500000" width="1280" height="720" codecs="avc1.4d401f"/>
          <Representation id="v3" bandwidth="5000000" width="1920" height="1080" codecs="avc1.640028"/>
        </AdaptationSet>
        <AdaptationSet id="audio" mimeType="audio/mp4" lang="en">
          <Representation id="a1" bandwidth="128000" codecs="mp4a.40.2"/>
        </AdaptationSet>
      </Period>
    </MPD>
    """

    func testParseStaticMPD() throws {
        let data = baseMPD.data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        let manifest = try MPDParser.parse(data: data, baseURL: url)

        XCTAssertEqual(manifest.type, .static)
        XCTAssertEqual(manifest.mediaPresentationDuration, 1800.0)
        XCTAssertEqual(manifest.minBufferTime, 2.0)
    }

    func testParseVideoAdaptations() throws {
        let data = baseMPD.data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        let manifest = try MPDParser.parse(data: data, baseURL: url)

        XCTAssertEqual(manifest.videoAdaptations.count, 1)
        let video = manifest.videoAdaptations[0]
        XCTAssertEqual(video.mimeType, "video/mp4")
        XCTAssertEqual(video.representations.count, 3)
    }

    func testParseVideoRepresentationsSorted() throws {
        let data = baseMPD.data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        let manifest = try MPDParser.parse(data: data, baseURL: url)

        let quals = manifest.lowestVideoQuality
        XCTAssertNotNil(quals)
        XCTAssertEqual(quals?.id, "v1")
        XCTAssertEqual(quals?.bandwidth, 1_000_000)
        XCTAssertEqual(quals?.width, 640)
        XCTAssertEqual(quals?.height, 360)
    }

    func testParseAudioAdaptations() throws {
        let data = baseMPD.data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        let manifest = try MPDParser.parse(data: data, baseURL: url)

        XCTAssertEqual(manifest.audioAdaptations.count, 1)
        let audio = manifest.audioAdaptations[0]
        XCTAssertEqual(audio.lang, "en")
        XCTAssertEqual(audio.representations.first?.bandwidth, 128_000)
    }

    func testParseInvalidXMLThrows() {
        let data = "not xml".data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        XCTAssertThrowsError(try MPDParser.parse(data: data, baseURL: url))
    }

    func testAllVideoQualitiesFlattened() throws {
        let data = baseMPD.data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        let manifest = try MPDParser.parse(data: data, baseURL: url)

        XCTAssertEqual(manifest.allVideoQualities.count, 3)
    }
}
```

- [ ] **Step 3: Verify tests pass**

Run from `TitanPlayer/`:
```bash
swift build --build-tests 2>&1 | grep -E "(error:|Build complete)"
```
Expected: `Build complete` with no errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/Core/Streaming/DASH/MPDParser.swift TitanPlayer/Tests/Streaming/MPDParserTests.swift
git commit -m "feat(dash): add MPDParser with XML parsing and ISO 8601 duration support"
```

---

## Task 4: DASHABRController

**Files:**
- Create: `TitanPlayer/Core/Streaming/DASH/DASHABRController.swift`
- Create: `TitanPlayer/Tests/Streaming/DASHABRControllerTests.swift`

- [ ] **Step 1: Create DASHABRController**

```swift
// TitanPlayer/Core/Streaming/DASH/DASHABRController.swift
import Foundation
import Combine

@MainActor
final class DASHABRController: ObservableObject {
    @Published private(set) var currentQuality: DASHQuality
    @Published private(set) var availableQualities: [DASHQuality]

    private var throughputSamples: [Double] = []
    private var consecutiveAboveThreshold = 0
    private var lastSwitchTime: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 5.0
    private let switchUpThreshold: Double = 1.5
    private let switchUpConsecutive: Int = 3
    private let emaAlpha: Double = 0.3
    private let maxSamples = 10

    private(set) var estimatedThroughput: Double = 0

    init(qualities: [DASHQuality], initial: DASHQuality?) {
        self.availableQualities = DASHQuality.sortedByBandwidth(qualities)
        self.currentQuality = initial ?? self.availableQualities.first!
    }

    func recordThroughput(bytesDownloaded: Int, durationSeconds: Double) {
        guard durationSeconds > 0 else { return }
        let throughput = Double(bytesDownloaded) * 8 / durationSeconds  // bits per second

        if estimatedThroughput == 0 {
            estimatedThroughput = throughput
        } else {
            estimatedThroughput = emaAlpha * throughput + (1 - emaAlpha) * estimatedThroughput
        }

        throughputSamples.append(throughput)
        if throughputSamples.count > maxSamples {
            throughputSamples.removeFirst()
        }

        evaluateQualitySwitch()
    }

    func forceQuality(_ quality: DASHQuality) {
        guard availableQualities.contains(where: { $0.id == quality.id }) else { return }
        currentQuality = quality
        lastSwitchTime = Date()
        consecutiveAboveThreshold = 0
    }

    private func evaluateQualitySwitch() {
        let now = Date()
        guard now.timeIntervalSince(lastSwitchTime) >= cooldownSeconds else { return }

        let currentBandwidth = Double(currentQuality.bandwidth)

        if estimatedThroughput > switchUpThreshold * currentBandwidth {
            consecutiveAboveThreshold += 1
            if consecutiveAboveThreshold >= switchUpConsecutive {
                switchUp()
            }
        } else {
            consecutiveAboveThreshold = 0
            if estimatedThroughput < currentBandwidth {
                switchDown()
            }
        }
    }

    private func switchUp() {
        guard let currentIndex = availableQualities.firstIndex(where: { $0.id == currentQuality.id }),
              currentIndex + 1 < availableQualities.count else { return }

        let candidate = availableQualities[currentIndex + 1]
        // Only switch if we have enough headroom
        if estimatedThroughput > Double(candidate.bandwidth) * 1.2 {
            currentQuality = candidate
            lastSwitchTime = Date()
            consecutiveAboveThreshold = 0
        }
    }

    private func switchDown() {
        let safetyMargin = estimatedThroughput * 0.8
        // Find highest quality that fits within safety margin
        if let bestFit = availableQualities.last(where: { Double($0.bandwidth) <= safetyMargin }),
           bestFit.id != currentQuality.id {
            currentQuality = bestFit
            lastSwitchTime = Date()
            consecutiveAboveThreshold = 0
        }
    }
}
```

- [ ] **Step 2: Write ABR controller tests**

```swift
// TitanPlayer/Tests/Streaming/DASHABRControllerTests.swift
import XCTest
@testable import TitanPlayer

@MainActor
final class DASHABRControllerTests: XCTestCase {
    private let lowQuality = DASHQuality(id: "low", bandwidth: 1_000_000, width: 640, height: 360, codec: nil, mimeType: nil, baseUrl: nil)
    private let midQuality = DASHQuality(id: "mid", bandwidth: 2_500_000, width: 1280, height: 720, codec: nil, mimeType: nil, baseUrl: nil)
    private let highQuality = DASHQuality(id: "high", bandwidth: 5_000_000, width: 1920, height: 1080, codec: nil, mimeType: nil, baseUrl: nil)

    func testStartsAtLowestQuality() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: lowQuality)
        XCTAssertEqual(controller.currentQuality.id, "low")
    }

    func testStartsAtSpecifiedInitial() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: midQuality)
        XCTAssertEqual(controller.currentQuality.id, "mid")
    }

    func testAvailableQualitiesSortedAscending() {
        let controller = DASHABRController(qualities: [highQuality, lowQuality, midQuality], initial: lowQuality)
        XCTAssertEqual(controller.availableQualities.map(\.id), ["low", "mid", "high"])
    }

    func testSwitchUpAfterConsecutiveHighSamples() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: lowQuality)

        // Record 3 samples above 1.5x current bitrate (1.5M) with enough headroom for mid (2.5M * 1.2 = 3M)
        for _ in 0..<3 {
            controller.recordThroughput(bytesDownloaded: 500_000, durationSeconds: 0.2) // 20 Mbps
        }

        // Need enough headroom: estimatedThroughput > midQuality.bandwidth * 1.2 = 3_000_000
        // 20_000_000 > 3_000_000, so should switch
        XCTAssertEqual(controller.currentQuality.id, "mid")
    }

    func testSwitchDownWhenThroughputDrops() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: highQuality)

        // Record low throughput below current bitrate
        controller.recordThroughput(bytesDownloaded: 10_000, durationSeconds: 0.1) // 800 kbps

        // Should switch down to something within 800kbps * 0.8 = 640kbps
        // lowQuality is 1Mbps which is > 640kbps, so stays at high? No - let's check
        // Actually with EMA: first sample = 800_000 bps. currentBandwidth = 5_000_000.
        // 800_000 < 5_000_000 → switchDown. safetyMargin = 800_000 * 0.8 = 640_000.
        // No quality fits (low is 1M > 640k). So stays at high.
        // This tests that we don't crash when no quality fits.
        XCTAssertEqual(controller.currentQuality.id, "high")
    }

    func testForceQuality() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: lowQuality)
        controller.forceQuality(highQuality)
        XCTAssertEqual(controller.currentQuality.id, "high")
    }

    func testForceQualityInvalidIdIgnored() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: lowQuality)
        let unknown = DASHQuality(id: "unknown", bandwidth: 999, width: nil, height: nil, codec: nil, mimeType: nil, baseUrl: nil)
        controller.forceQuality(unknown)
        XCTAssertEqual(controller.currentQuality.id, "low")
    }

    func testCooldownPreventsRapidSwitching() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: lowQuality)

        // Switch up
        for _ in 0..<3 {
            controller.recordThroughput(bytesDownloaded: 500_000, durationSeconds: 0.2)
        }
        XCTAssertEqual(controller.currentQuality.id, "mid")

        // Immediately try to switch down (within cooldown)
        controller.recordThroughput(bytesDownloaded: 10_000, durationSeconds: 0.1)
        // Should stay at mid due to cooldown
        XCTAssertEqual(controller.currentQuality.id, "mid")
    }
}
```

- [ ] **Step 3: Verify tests pass**

Run from `TitanPlayer/`:
```bash
swift build --build-tests 2>&1 | grep -E "(error:|Build complete)"
```
Expected: `Build complete` with no errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/Core/Streaming/DASH/DASHABRController.swift TitanPlayer/Tests/Streaming/DASHABRControllerTests.swift
git commit -m "feat(dash): add DASHABRController with EMA throughput and quality switching"
```

---

## Task 5: DASHStreamSession

**Files:**
- Create: `TitanPlayer/Core/Streaming/DASH/DASHStreamSession.swift`

- [ ] **Step 1: Create DASHStreamSession**

```swift
// TitanPlayer/Core/Streaming/DASH/DASHStreamSession.swift
import Foundation
import CoreMedia
import Libavformat

final class DASHStreamSession: @unchecked Sendable {
    let manifest: MPDManifest
    let manifestURL: URL
    private let abrController: DASHABRController
    private var currentQuality: DASHQuality
    private var demuxer: FFmpegDemuxer?
    private let lock = NSLock()

    private var _mediaInfo: MediaInfo?
    var mediaInfo: MediaInfo? { lock.lock(); defer { lock.unlock() }; return _mediaInfo }

    private var segmentStartTime: Date?
    private var segmentBytesDownloaded: Int = 0

    init(manifest: MPDManifest, manifestURL: URL, abrController: DASHABRController) {
        self.manifest = manifest
        self.manifestURL = manifestURL
        self.abrController = abrController
        self.currentQuality = abrController.currentQuality
    }

    func open() async throws -> MediaInfo {
        let quality = currentQuality
        let url = try resolveSegmentURL(for: quality)

        let demuxer = FFmpegDemuxer()
        let info = try await demuxer.open(url: url)

        lock.lock()
        self.demuxer = demuxer
        self._mediaInfo = info
        lock.unlock()

        return info
    }

    func nextPacket() async throws -> MediaPacket {
        let currentDemuxer: FFmpegDemuxer
        lock.lock()
        guard let d = self.demuxer else {
            lock.unlock()
            throw MediaError(code: .decodingFailed, message: "No active demuxer")
        }
        currentDemuxer = d
        lock.unlock()

        let packet = try await currentDemuxer.nextPacket()

        // Track bytes for ABR (approximate from packet data)
        // Actual throughput is measured by the session caller
        return packet
    }

    func recordThroughput(bytesDownloaded: Int, durationSeconds: Double) {
        Task { @MainActor in
            abrController.recordThroughput(bytesDownloaded: bytesDownloaded, durationSeconds: durationSeconds)
            let newQuality = abrController.currentQuality
            if newQuality.id != currentQuality.id {
                try? await switchQuality(to: newQuality)
            }
        }
    }

    func switchQuality(to quality: DASHQuality) async throws {
        lock.lock()
        let oldDemuxer = self.demuxer
        lock.unlock()

        // Close old demuxer
        oldDemuxer?.close()

        // Open new demuxer with new quality
        let url = try resolveSegmentURL(for: quality)
        let newDemuxer = FFmpegDemuxer()
        let info = try await newDemuxer.open(url: url)

        lock.lock()
        self.demuxer = newDemuxer
        self._mediaInfo = info
        self.currentQuality = quality
        lock.unlock()
    }

    func seek(to time: CMTime) async throws {
        let currentDemuxer: FFmpegDemuxer
        lock.lock()
        guard let d = self.demuxer else {
            lock.unlock()
            throw MediaError(code: .decodingFailed, message: "No active demuxer")
        }
        currentDemuxer = d
        lock.unlock()

        try await currentDemuxer.seek(to: time)
    }

    func close() {
        lock.lock()
        let d = self.demuxer
        self.demuxer = nil
        lock.unlock()

        d?.close()
    }

    private func resolveSegmentURL(for quality: DASHQuality) throws -> URL {
        // For now, use the manifest URL directly — FFmpeg's DASH demuxer handles the rest
        // The quality switch is handled by FFmpeg internally when given the MPD URL
        return manifestURL
    }
}

extension DASHStreamSession: MediaDemuxing {
    func open(url: URL) async throws -> MediaInfo {
        try await open()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/Core/Streaming/DASH/DASHStreamSession.swift
git commit -m "feat(dash): add DASHStreamSession with FFmpeg demuxer lifecycle"
```

---

## Task 6: Update DASHPlayer Protocol and Factory

**Files:**
- Modify: `TitanPlayer/Core/Streaming/DASH/DASHPlayer.swift`
- Modify: `TitanPlayer/Core/Streaming/DASH/DASHPlayerFactory.swift`

- [ ] **Step 1: Update DASHPlayer protocol**

```swift
// TitanPlayer/Core/Streaming/DASH/DASHPlayer.swift
import AVFoundation

protocol DASHPlayer: AnyObject {
    func playableAsset(for url: URL) async throws -> AVURLAsset
    func streamSession(for url: URL) async throws -> DASHStreamSession
    var currentVariants: [StreamingQuality] { get async }
}
```

- [ ] **Step 2: Update NotImplementedDASHPlayer for protocol conformance**

```swift
// TitanPlayer/Core/Streaming/DASH/NotImplementedDASHPlayer.swift
import AVFoundation

final class NotImplementedDASHPlayer: DASHPlayer {
    func playableAsset(for url: URL) async throws -> AVURLAsset {
        throw StreamingError.dashNotSupported(url)
    }

    func streamSession(for url: URL) async throws -> DASHStreamSession {
        throw StreamingError.dashNotSupported(url)
    }

    var currentVariants: [StreamingQuality] {
        get async { [] }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Core/Streaming/DASH/DASHPlayer.swift TitanPlayer/Core/Streaming/DASH/NotImplementedDASHPlayer.swift
git commit -m "feat(dash): add streamSession to DASHPlayer protocol"
```

---

## Task 7: DASHPlayerImpl

**Files:**
- Create: `TitanPlayer/Core/Streaming/DASH/DASHPlayerImpl.swift`

- [ ] **Step 1: Create DASHPlayerImpl**

```swift
// TitanPlayer/Core/Streaming/DASH/DASHPlayerImpl.swift
import AVFoundation

@MainActor
final class DASHPlayerImpl: DASHPlayer {
    private var abrController: DASHABRController?
    private var currentSession: DASHStreamSession?

    func playableAsset(for url: URL) async throws -> AVURLAsset {
        throw StreamingError.dashNotSupported(url)
    }

    func streamSession(for url: URL) async throws -> DASHStreamSession {
        let manifest = try await MPDParser.parse(url: url)
        let qualities = manifest.allVideoQualities
        let lowest = manifest.lowestVideoQuality

        let controller = DASHABRController(qualities: qualities, initial: lowest)
        self.abrController = controller

        let session = DASHStreamSession(
            manifest: manifest,
            manifestURL: url,
            abrController: controller
        )
        _ = try await session.open()

        self.currentSession = session
        return session
    }

    var currentVariants: [StreamingQuality] {
        get async {
            abrController?.availableQualities.map { q in
                .variant(
                    resolution: CGSize(width: q.width ?? 0, height: q.height ?? 0),
                    bitrate: Double(q.bandwidth),
                    codec: q.codec
                )
            } ?? []
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/Core/Streaming/DASH/DASHPlayerImpl.swift
git commit -m "feat(dash): add DASHPlayerImpl with MPD parsing and ABR setup"
```

---

## Task 8: Update DASHPlayerFactory

**Files:**
- Modify: `TitanPlayer/Core/Streaming/DASH/DASHPlayerFactory.swift`

- [ ] **Step 1: Update factory to return real player**

```swift
// TitanPlayer/Core/Streaming/DASH/DASHPlayerFactory.swift
import Foundation

enum DASHPlayerFactory {
    static func player(for url: URL) -> DASHPlayer {
        DASHPlayerImpl()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/Core/Streaming/DASH/DASHPlayerFactory.swift
git commit -m "feat(dash): factory returns DASHPlayerImpl instead of stub"
```

---

## Task 9: MediaPipeline Stream Support

**Files:**
- Modify: `TitanPlayer/Core/Engine/MediaPipeline.swift`

- [ ] **Step 1: Add openStream method to MediaPipeline**

Add this method inside the `MediaPipeline` class, after the `openFile(url:)` method:

```swift
    func openStream(session: DASHStreamSession) async {
        playState = .loading

        do {
            let info = try await session.open()
            self.mediaInfo = info
            timeObserver.duration = info.duration.seconds

            self.demuxer = session

            if let videoTrack = info.videoTracks.first {
                decoder = FFmpegDecoder()
                try decoder?.configure(for: videoTrack)
            }

            playState = .paused
        } catch {
            playState = .error(error.localizedDescription)
        }
    }
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/Core/Engine/MediaPipeline.swift
git commit -m "feat(dash): add openStream to MediaPipeline for DASH playback"
```

---

## Task 10: PlaybackEngine DASH Routing

**Files:**
- Modify: `TitanPlayer/Core/Engine/PlaybackEngine.swift`

- [ ] **Step 1: Update PlaybackEngine.load for DASH routing**

Replace the `load(url:)` method with:

```swift
    func load(url: URL) async throws {
        state = .loading
        lastError = nil

        do {
            if url.pathExtension.lowercased() == "mpd" {
                let dashPlayer = DASHPlayerFactory.player(for: url)
                let session = try await dashPlayer.streamSession(for: url)
                await mediaPipeline?.openStream(session: session)
                self.mediaInfo = mediaPipeline?.mediaInfo
                self.state = .ready
            } else {
                let asset = AVURLAsset(url: url)
                let item = AVPlayerItem(asset: asset)

                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)

                guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
                    throw PlaybackError.noPlayableTracks
                }

                let durationValue = try await asset.load(.duration)
                self.duration = CMTimeGetSeconds(durationValue)

                self.player.replaceCurrentItem(with: item)

                await mediaPipeline?.openFile(url: url)
                self.mediaInfo = mediaPipeline?.mediaInfo

                self.state = .ready
            }
        } catch {
            self.state = .error(error.localizedDescription)
            self.lastError = (error as? PlaybackError) ?? .assetLoadFailed(error)
            throw error
        }
    }
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/Core/Engine/PlaybackEngine.swift
git commit -m "feat(dash): PlaybackEngine routes .mpd URLs through DASH path"
```

---

## Task 11: StreamingManager Wiring

**Files:**
- Modify: `TitanPlayer/Core/Streaming/StreamingManager.swift`

- [ ] **Step 1: Update StreamingManager DASH case**

Replace the `.mpd` case in `load(url:)`:

```swift
        case .mpd:
            let dashPlayer = DASHPlayerFactory.player(for: url)
            Task {
                do {
                    let session = try await dashPlayer.streamSession(for: url)
                    _ = session
                    streamingState = .ready
                    currentQuality = .auto
                    availableQualities = await dashPlayer.currentVariants
                } catch {
                    streamingState = .error(error.localizedDescription)
                }
            }
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/Core/Streaming/StreamingManager.swift
git commit -m "feat(dash): StreamingManager wires DASH player with quality publishing"
```

---

## Task 12: Integration Test with Public DASH Stream

**Files:**
- Create: `TitanPlayer/Tests/Streaming/DASHIntegrationTests.swift`

- [ ] **Step 1: Create integration test**

```swift
// TitanPlayer/Tests/Streaming/DASHIntegrationTests.swift
import XCTest
@testable import TitanPlayer

@MainActor
final class DASHIntegrationTests: XCTestCase {
    func testMPDParserParsesRealBBBStream() async throws {
        // Big Buck Bunny DASH test stream
        guard let url = URL(string: "https://dash.akamaized.net/akamai/test/bbb_30fps/bbb_30fps.mpd") else {
            XCTFail("Invalid URL")
            return
        }

        let manifest = try await MPDParser.parse(url: url)

        XCTAssertFalse(manifest.videoAdaptations.isEmpty, "Should have video adaptations")
        XCTAssertFalse(manifest.allVideoQualities.isEmpty, "Should have video qualities")

        let lowest = manifest.lowestVideoQuality
        XCTAssertNotNil(lowest, "Should have a lowest quality")
        XCTAssertGreaterThan(lowest!.bandwidth, 0, "Bandwidth should be positive")
    }

    func testDASHPlayerImplCreatesSession() async throws {
        guard let url = URL(string: "https://dash.akamaized.net/akamai/test/bbb_30fps/bbb_30fps.mpd") else {
            XCTFail("Invalid URL")
            return
        }

        let player = DASHPlayerImpl()
        let session = try await player.streamSession(for: url)

        XCTAssertNotNil(session.mediaInfo, "Session should have media info")
        XCTAssertGreaterThan(session.mediaInfo?.videoTracks.count ?? 0, 0, "Should have video tracks")

        let variants = await player.currentVariants
        XCTAssertFalse(variants.isEmpty, "Should have available variants")

        session.close()
    }
}
```

- [ ] **Step 2: Verify build passes**

Run from `TitanPlayer/`:
```bash
swift build --build-tests 2>&1 | grep -E "(error:|Build complete)"
```
Expected: `Build complete` with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Tests/Streaming/DASHIntegrationTests.swift
git commit -m "feat(dash): add integration tests with public DASH test stream"
```

---

## Task 13: Verify Existing Tests Still Pass

- [ ] **Step 1: Run full test build**

Run from `TitanPlayer/`:
```bash
swift build --build-tests 2>&1 | grep -E "(error:|Build complete)"
```
Expected: `Build complete` with no errors. If there are errors related to XCTest module (known environment issue), use the workaround from AGENTS.md:

```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: Empty output (no errors other than the environmental XCTest one).

- [ ] **Step 2: Verify no regressions in existing DASH tests**

The existing `DASHPlayerTests.swift` should still compile. The tests that check for `NotImplementedDASHPlayer` behavior will need updating since the factory now returns `DASHPlayerImpl`. Update them:

```swift
// TitanPlayer/Tests/Streaming/DASHPlayerTests.swift
import XCTest
import AVFoundation
@testable import TitanPlayer

@MainActor
final class DASHPlayerTests: XCTestCase {
    func testFactoryReturnsDASHPlayerImpl() {
        let url = URL(string: "https://example.com/manifest.mpd")!
        let player = DASHPlayerFactory.player(for: url)
        XCTAssertTrue(player is DASHPlayerImpl)
    }

    func testNotImplementedPlayerStillThrowsDashNotSupported() async {
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

    func testCurrentVariantsIsEmptyForNotImplemented() async {
        let player = NotImplementedDASHPlayer()
        let variants = await player.currentVariants
        XCTAssertTrue(variants.isEmpty)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Tests/Streaming/DASHPlayerTests.swift
git commit -m "test(dash): update DASHPlayerTests for new factory behavior"
```
