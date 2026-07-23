import Foundation

@frozen enum TelemetryEvent: Sendable {
    case playbackFailed(
        codec: String,
        resolution: String,
        errorCode: String,
        source: PlaybackSource
    )
    
    case hdrModeUsed(
        mode: TelemetryHDRMode,
        duration: TimeInterval
    )
    
    case performanceSnapshot(
        averageCPU: Double,
        averageGPU: Double,
        resolution: String,
        codec: String
    )
    
    case audioFormatUsed(
        format: TelemetryAudioFormat,
        sampleRate: Int,
        bitDepth: Int
    )

    case compatibilityModeActivated(
        reason: String,
        source: PlaybackSource
    )

    case frameCacheEvicted(
        count: Int,
        reason: String
    )

    /// Emitted whenever the active network path changes (e.g. a Wi-Fi ↔
    /// cellular handover that the ABR selector must react to), or when the path
    /// becomes expensive/constrained. Kept stringly-typed at the edges
    /// (`previous`/`current` reach labels) so events stay `Sendable` and
    /// privacy-safe.
    case networkStateChanged(
        previous: String,
        current: String,
        expensive: Bool,
        constrained: Bool,
        source: PlaybackSource
    )

    /// Emitted when a CoreSpotlight indexing pass completes successfully.
    case spotlightIndexed(
        count: Int,
        duration: TimeInterval,
        source: PlaybackSource
    )

    /// Emitted when a CoreSpotlight indexing pass fails (error mapped onto
    /// ``MediaError``). Kept stringly-typed at the `errorCode` edge so events
    /// stay `Sendable` and privacy-safe.
    case spotlightIndexingFailed(
        errorCode: String,
        source: PlaybackSource
    )

    /// Emitted when a FairPlay content key is successfully acquired. Kept
    /// stringly-typed at the edges (just the playback `source`) so events stay
    /// `Sendable` and privacy-safe.
    case drmKeyLoaded(source: PlaybackSource)

    /// Emitted after a display capability detection pass completes
    /// successfully. `stableID` is the CoreGraphics display identifier (or
    /// `"unknown"`), and the remaining fields summarize the resolved HDR/EDR
    /// and gamut state so HDR pipeline decisions can be audited.
    case displayCapabilitiesDetected(
        stableID: String,
        supportsHDR: Bool,
        supportsEDR: Bool,
        colorGamut: String,
        source: PlaybackSource
    )

    /// Emitted when a display capability detection pass fails. The `errorCode`
    /// is the ``MediaError/Kind/rawValueForTelemetry`` bucket so failures stay
    /// `Sendable` and privacy-safe.
    case displayDetectionFailed(
        errorCode: String,
        source: PlaybackSource
    )

    /// Emitted when a library asset prefetch pass completes successfully.
    /// `count` is the number of items resolved and `duration` the wall-clock
    /// cost of the pass, so library-browsing cost can be audited.
    case libraryAssetsPrefetched(
        count: Int,
        duration: TimeInterval,
        source: PlaybackSource
    )

    /// Emitted when a single library asset prefetch item fails. The `errorCode`
    /// is the ``MediaError/Kind/rawValueForTelemetry`` bucket so failures stay
    /// `Sendable` and privacy-safe.
    case libraryPrefetchFailed(
        errorCode: String,
        source: PlaybackSource
    )
}

enum PlaybackSource: String, Sendable {
    case local
    case hls
    case dash
}

enum TelemetryHDRMode: String, Sendable {
    case hdr10
    case dolbyVision
    case hlg
}

enum TelemetryAudioFormat: String, Sendable {
    case atmos
    case stereo
    case spatial
    case surround5_1
}
