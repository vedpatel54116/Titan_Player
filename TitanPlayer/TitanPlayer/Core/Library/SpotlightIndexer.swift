import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import Combine
import OSLog

// MARK: - SpotlightIndexer

/// Indexes media into CoreSpotlight so library content surfaces in system
/// (Spotlight) search — a capability Titan Player previously lacked.
///
/// ## Design
/// - **Concurrency:** The type is a `final actor`, which makes it genuinely
///   `Sendable` (no `@unchecked`) and serializes all CoreSpotlight access. The
///   non-`Sendable` `CSSearchableItem` / `CSSearchableItemAttributeSet`
///   references are built and handed to CoreSpotlight *synchronously* within a
///   single isolation boundary, never captured across one.
/// - **Decoupled input:** The indexer consumes ``SpotlightIndexItem``, a small
///   `Sendable` projection, so it does not couple to the app's domain
///   `MediaItem` (and its UI counterpart). Callers map their model to
///   ``SpotlightIndexItem`` before indexing.
/// - **Pressure awareness:** Indexing pauses when the system is under critical
///   thermal or memory pressure (mapped onto ``MediaError``), and continues with
///   a warning under lesser pressure. The engine feeds live state via
///   ``handleSystemState(_:)``; the indexer also self-checks
///   `ProcessInfo.thermalState` as a fallback.
/// - **Cancellation & timeouts:** Every batch honors cooperative cancellation
///   (`Task.checkCancellation()`) and a per-operation wall-clock timeout, both
///   mapped onto ``MediaError``.
/// - **Telemetry:** Lifecycle events are emitted only through the injected
///   ``TelemetrySink`` (which hops to `TelemetryManager.shared` on the main
///   actor). Sentry is never referenced directly.
///
/// ## Example
/// ```swift
/// let indexer = SpotlightIndexer()
/// try await indexer.index([SpotlightIndexItem(id: item.id, title: item.title, …)])
/// // later, when an item is deleted:
/// try await indexer.deindex(identifiers: [item.id])
/// ```
final actor SpotlightIndexer {

    // MARK: - Input projection

    /// A `Sendable` projection of a media item, carrying only what CoreSpotlight
    /// needs. Decouples the indexer from the app's domain `MediaItem`.
    struct SpotlightIndexItem: Sendable, Hashable {
        let id: UUID
        let title: String
        let displayTitle: String
        let duration: TimeInterval
        let dateAdded: Date
        let dateModified: Date
        let fileSize: UInt64
        let isVideo: Bool
        let isHDR: Bool
        let isFavorite: Bool
        let thumbnailPath: String?
        let codec: String?
        let resolution: CGSize?
    }

    // MARK: - Configuration

    /// Runtime tuning for the indexer.
    struct Configuration: Sendable {
        /// Maximum number of items submitted to CoreSpotlight per batch. Keeps
        /// individual `indexSearchableItems` calls bounded for memory and
        /// timeout control.
        var batchSize: Int = 50
        /// Wall-clock budget for a single CoreSpotlight operation, in seconds.
        /// Exceeding it cancels the operation and surfaces ``MediaError/Kind/timedOut``.
        var operationTimeout: TimeInterval = 30
        /// The CoreSpotlight domain identifier shared by every indexed item, so
        /// `deleteSearchableItems(withDomainIdentifiers:)` can clear only our
        /// content without touching other apps' items.
        var domainIdentifier: String = "com.titanplayer.media"

        static let `default` = Configuration()
    }

    // MARK: - Progress reporting

    /// Coarse phase of an indexing pass, emitted on ``indexProgressPublisher``.
    enum IndexPhase: Sendable {
        case started
        case indexing
        case completed
        case failed
        case cancelled
    }

    /// A point-in-time progress snapshot for an indexing pass.
    struct IndexProgress: Sendable {
        let phase: IndexPhase
        let indexedCount: Int
        let totalCount: Int
        let timestamp: Date
    }

    /// The outcome of an indexing pass.
    struct IndexResult: Sendable {
        /// Number of items successfully handed to CoreSpotlight.
        let indexedCount: Int
        /// Number of items skipped (e.g. empty input).
        let skippedCount: Int
        /// Wall-clock duration of the pass.
        let duration: TimeInterval
    }

    // MARK: - Telemetry Sink

    /// A `Sendable` bridge to ``TelemetryProviding`` so the actor never stores a
    /// non-`Sendable` telemetry reference. The default sink hops to the main
    /// actor and records through `TelemetryManager.shared` — Sentry is never
    /// referenced directly.
    struct TelemetrySink: Sendable {
        let record: @Sendable (TelemetryEvent) -> Void

        static let `default` = TelemetrySink { event in
            Task { @MainActor in TelemetryManager.shared.record(event) }
        }
    }

    // MARK: - Private state

    private let logger = Logger(subsystem: "com.titanplayer", category: "SpotlightIndexer")
    private let configuration: Configuration
    private let telemetry: TelemetrySink
    private let progressBox: ProgressSubjectBox

    /// Latest system-pressure snapshot supplied by the engine. The indexer also
    /// consults `ProcessInfo.thermalState` directly as a fallback.
    private var systemState: SystemStateSnapshot = .nominal

    // MARK: - Initialization

    /// Creates a spotlight indexer.
    ///
    /// - Parameters:
    ///   - configuration: Runtime tuning. Defaults to `Configuration.default`.
    ///   - telemetry: Telemetry sink. Defaults to `TelemetrySink.default`.
    init(
        configuration: Configuration = .default,
        telemetry: TelemetrySink = .default
    ) {
        self.configuration = configuration
        self.telemetry = telemetry
        self.progressBox = ProgressSubjectBox()
    }

    // MARK: - Public API

    /// Indexes the supplied items into CoreSpotlight.
    ///
    /// Items are submitted in batches (see ``Configuration/batchSize``). The
    /// operation is cancelled cooperatively, bounded by
    /// ``Configuration/operationTimeout`` per batch, and paused under critical
    /// system pressure.
    ///
    /// - Parameter items: The items to index.
    /// - Returns: An ``IndexResult`` summarizing the pass.
    /// - Throws: ``MediaError`` on cancellation, timeout, critical system
    ///   pressure, or a CoreSpotlight failure.
    func index(_ items: [SpotlightIndexItem]) async throws -> IndexResult {
        try Task.checkCancellation()

        guard !items.isEmpty else {
            logger.debug("Spotlight index called with empty item list; nothing to do.")
            return IndexResult(indexedCount: 0, skippedCount: 0, duration: 0)
        }

        let domain = configuration.domainIdentifier
        let timeout = configuration.operationTimeout
        try throwIfPaused()
        emitProgress(.init(phase: .started, indexedCount: 0, totalCount: items.count, timestamp: Date()))

        let start = Date()
        var indexedCount = 0

        for batch in items.chunked(into: configuration.batchSize) {
            try Task.checkCancellation()
            try throwIfPaused()

            let batchItems = batch
            try await Self.withTimeout(seconds: timeout, source: .local) {
                let searchable = batchItems.map { Self.makeSearchableItem(for: $0, domain: domain) }
                try await Self.indexBatch(searchable)
            }

            indexedCount += batch.count
            emitProgress(.init(phase: .indexing, indexedCount: indexedCount, totalCount: items.count, timestamp: Date()))
        }

        let duration = Date().timeIntervalSince(start)
        emitProgress(.init(phase: .completed, indexedCount: indexedCount, totalCount: items.count, timestamp: Date()))
        telemetry.record(.spotlightIndexed(count: indexedCount, duration: duration, source: .local))
        logger.info("Spotlight indexed \(indexedCount) item(s) in \(String(format: "%.2f", duration))s.")

        return IndexResult(indexedCount: indexedCount, skippedCount: 0, duration: duration)
    }

    /// Replaces the entire index with `items`: clears all previously indexed
    /// content (within our domain) and indexes the new set.
    ///
    /// - Parameter items: The items that should be the sole contents of the index.
    /// - Returns: An ``IndexResult`` for the indexing half of the operation.
    /// - Throws: ``MediaError`` as described in ``index(_:)``.
    func reindex(_ items: [SpotlightIndexItem]) async throws -> IndexResult {
        try Task.checkCancellation()
        try await deindexAll()
        return try await index(items)
    }

    /// Removes the given items from the index by identifier.
    ///
    /// - Parameter identifiers: The identifiers to remove.
    /// - Throws: ``MediaError`` on cancellation, timeout, or CoreSpotlight failure.
    func deindex(identifiers: [UUID]) async throws {
        try Task.checkCancellation()
        guard !identifiers.isEmpty else { return }

        let ids = identifiers.map { $0.uuidString }
        let timeout = configuration.operationTimeout
        try await Self.withTimeout(seconds: timeout, source: .local) {
            try await Self.deleteItems(withIdentifiers: ids)
        }
        logger.debug("Spotlight deindexed \(ids.count) identifier(s).")
    }

    /// Removes every Titan Player item from the index (within our domain).
    ///
    /// - Throws: ``MediaError`` on cancellation, timeout, or CoreSpotlight failure.
    func deindexAll() async throws {
        try Task.checkCancellation()
        let timeout = configuration.operationTimeout
        let domain = configuration.domainIdentifier
        try await Self.withTimeout(seconds: timeout, source: .local) {
            try await Self.deleteDomain(domain)
        }
        logger.debug("Spotlight cleared all indexed items.")
    }

    /// A continuously-updating stream of ``IndexProgress`` for the most recent
    /// pass. Backed by a Combine `PassthroughSubject`; subscribers receive
    /// progress events as they are emitted.
    var indexProgressPublisher: AnyPublisher<IndexProgress, Never> {
        progressBox.publisher
    }

    // MARK: - System pressure handling

    /// Feeds the latest system-health snapshot from the engine.
    ///
    /// Indexing pauses (throwing ``MediaError/Kind/thermalPressure`` or
    /// ``MediaError/Kind/memoryPressure``) when the snapshot reports a critical
    /// condition, and logs a warning under lesser pressure.
    ///
    /// - Parameter snapshot: The current ``SystemStateSnapshot``.
    func handleSystemState(_ snapshot: SystemStateSnapshot) {
        systemState = snapshot
    }

    /// Convenience for feeding just a thermal level.
    func handleThermalState(_ state: ThermalLevel) {
        systemState = SystemStateSnapshot(thermal: state, memory: systemState.memory, observedAt: Date())
    }

    /// Convenience for feeding just a memory-pressure level.
    func handleMemoryPressure(_ level: MemoryPressureLevel) {
        systemState = SystemStateSnapshot(thermal: systemState.thermal, memory: level, observedAt: Date())
    }

    /// `true` when system pressure is severe enough that indexing should pause.
    var isSuspended: Bool { systemState.shouldPauseForSystem }

    // MARK: - Cancellation & timeout helpers

    /// Throws the appropriate ``MediaError`` when indexing must pause for system
    /// pressure. Consults both the engine-supplied snapshot and the live
    /// `ProcessInfo.thermalState` so the indexer self-protects even if no
    /// snapshot has been fed.
    private func throwIfPaused() throws {
        let thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        let memory = systemState.memory

        if thermal == .critical {
            let error = MediaError.thermalPressure(source: .local)
            emitProgress(.init(phase: .failed, indexedCount: 0, totalCount: 0, timestamp: Date()))
            telemetry.record(.spotlightIndexingFailed(errorCode: error.telemetryErrorCode, source: .local))
            throw error
        }
        if memory == .critical {
            let error = MediaError.memoryPressure(source: .local)
            emitProgress(.init(phase: .failed, indexedCount: 0, totalCount: 0, timestamp: Date()))
            telemetry.record(.spotlightIndexingFailed(errorCode: error.telemetryErrorCode, source: .local))
            throw error
        }
        if thermal == .serious || memory == .warning {
            logger.warning("Spotlight indexing continuing under system pressure (thermal=\(thermal.description), memory=\(memory.description)).")
        }
    }

    /// Races `operation` against a wall-clock timeout, mapping the timeout to
    /// ``MediaError/Kind/timedOut``. Declared `nonisolated` so it can be called
    /// from the actor while its `@Sendable` `operation` runs off-island.
    nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        source: PlaybackSource = .local,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MediaError(
                    kind: .timedOut,
                    source: source,
                    underlyingDomain: "SpotlightIndexer",
                    underlyingMessage: "Operation exceeded \(seconds)s budget.",
                    message: "Spotlight indexing operation timed out."
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MediaError(kind: .unknown, source: source, message: "Spotlight operation produced no result.")
            }
            return result
        }
    }

    // MARK: - CoreSpotlight bridging

    /// Builds a `CSSearchableItem` from a ``SpotlightIndexItem``. Pure and
    /// non-isolated: no actor state is touched, so it is safe to run inside a
    /// `@Sendable` task-group closure.
    nonisolated static func makeSearchableItem(for item: SpotlightIndexItem, domain: String) -> CSSearchableItem {
        let contentType: UTType = item.isVideo ? .movie : .audio
        let attributeSet = CSSearchableItemAttributeSet(contentType: contentType)
        attributeSet.title = item.displayTitle
        attributeSet.displayName = item.displayTitle
        attributeSet.contentDescription = Self.describe(item)
        attributeSet.duration = item.duration as NSNumber
        attributeSet.fileSize = item.fileSize as NSNumber
        attributeSet.addedDate = item.dateAdded
        attributeSet.contentModificationDate = item.dateModified
        attributeSet.keywords = Self.keywords(for: item)

        if let thumbnailPath = item.thumbnailPath {
            attributeSet.thumbnailURL = URL(fileURLWithPath: thumbnailPath)
        }
        if let codec = item.codec {
            attributeSet.codecs = [codec]
        }

        return CSSearchableItem(
            uniqueIdentifier: item.id.uuidString,
            domainIdentifier: domain,
            attributeSet: attributeSet
        )
    }

    /// Submits items to the default CoreSpotlight index, resuming the continuation
    /// with a ``MediaError`` on failure. Non-isolated so it can be awaited from a
    /// `@Sendable` task-group closure.
    nonisolated static func indexBatch(_ items: [CSSearchableItem]) async throws {
        guard !items.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: MediaError(error, source: .local))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Deletes items by identifier from the default CoreSpotlight index.
    nonisolated static func deleteItems(withIdentifiers identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers) { error in
                if let error {
                    continuation.resume(throwing: MediaError(error, source: .local))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Deletes every Titan Player item (within `domain`) from the default index
    /// via the domain-identifier deletion API, leaving other apps' items intact.
    nonisolated static func deleteDomain(_ domain: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { error in
                if let error {
                    continuation.resume(throwing: MediaError(error, source: .local))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Attribute helpers

    /// Human-readable description for the Spotlight item.
    private static func describe(_ item: SpotlightIndexItem) -> String {
        var parts: [String] = [item.title]
        if let codec = item.codec { parts.append("Codec: \(codec)") }
        if item.isHDR { parts.append("HDR") }
        if let resolution = item.resolution {
            parts.append("\(Int(resolution.width))×\(Int(resolution.height))")
        }
        if item.duration > 0 {
            let minutes = Int(item.duration) / 60
            let seconds = Int(item.duration) % 60
            parts.append(String(format: "Duration: %d:%02d", minutes, seconds))
        }
        return parts.joined(separator: " · ")
    }

    /// Search keywords derived from the item, improving recall in Spotlight.
    private static func keywords(for item: SpotlightIndexItem) -> [String] {
        var keywords = ["Titan Player", item.title]
        if let codec = item.codec { keywords.append(codec) }
        if item.isHDR { keywords.append("HDR") }
        if item.isFavorite { keywords.append("favorite") }
        return keywords
    }

    // MARK: - Progress emission

    private func emitProgress(_ progress: IndexProgress) {
        progressBox.send(progress)
    }
}

// MARK: - Array chunking

extension Array {
    /// Splits the array into consecutive sub-arrays of at most `size` elements.
    fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - ProgressSubjectBox

/// `@unchecked Sendable` box around a Combine `PassthroughSubject` so the actor
/// can expose progress without storing a non-`Sendable` subject directly. Sends
/// occur only from the actor, matching the ``TelemetryBox`` pattern elsewhere.
private final class ProgressSubjectBox: @unchecked Sendable {
    let subject = PassthroughSubject<SpotlightIndexer.IndexProgress, Never>()

    func send(_ value: SpotlightIndexer.IndexProgress) {
        subject.send(value)
    }

    var publisher: AnyPublisher<SpotlightIndexer.IndexProgress, Never> {
        subject.eraseToAnyPublisher()
    }
}
