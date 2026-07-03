import Foundation

// MARK: - Decoder Selection

struct DecoderSelection: Sendable {
    let decoder: VideoDecoding
    let reason: ScoreReason
}

// MARK: - Decoder Preference

enum DecoderPreference: Sendable, Equatable {
    case preferHardware
    case preferSoftware
    case neutral
}

// MARK: - Score Reason

enum ScoreReason: Sendable {
    case codecSupported
    case hardwareAvailable
    case goodPerformance
    case thermalEfficient
    case resolutionSupported
    case fallback
    case userPreference
}

// MARK: - Decoder Score

struct DecoderScore: Sendable {
    let score: Double
    let reasons: [ScoreReason]
}

// MARK: - Decoder Selector

struct DecoderSelector {

    // MARK: - Decoder Caches

    private var hwDecoderCache: [String: VideoToolboxDecoder] = [:]
    private var swDecoderCache: [String: FFmpegSoftwareDecoder] = [:]

    // MARK: - Selection Logic

    func selectDecoder(for track: VideoTrackInfo,
                       available: [VideoDecoding],
                       systemState: SystemState,
                       preference: DecoderPreference = .neutral) -> DecoderSelection {

        let scored = available.map { decoder in
            (decoder: decoder, score: calculateScore(for: decoder, track: track, systemState: systemState, preference: preference))
        }

        let sorted = scored.sorted { $0.score.score > $1.score.score }

        guard let best = sorted.first else {
            return DecoderSelection(decoder: available.first!, reason: .fallback)
        }

        return DecoderSelection(decoder: best.decoder, reason: best.score.reasons.first ?? .fallback)
    }
    
    // MARK: - Cached Decoder Access

    mutating func cachedDecoder(for track: VideoTrackInfo, preferHardware: Bool) -> VideoDecoding {
        let key = "\(track.codec)_\(track.width)x\(track.height)"

        if preferHardware {
            if let cached = hwDecoderCache[key] {
                return cached
            }
            let decoder = VideoToolboxDecoder()
            hwDecoderCache[key] = decoder
            return decoder
        } else {
            if let cached = swDecoderCache[key] {
                return cached
            }
            let decoder = FFmpegSoftwareDecoder()
            swDecoderCache[key] = decoder
            return decoder
        }
    }

    mutating func invalidateCaches() {
        hwDecoderCache.removeAll()
        swDecoderCache.removeAll()
    }
    
    // MARK: - Switch Check

    func checkForSwitch(current: VideoDecoding,
                        systemState: SystemState,
                        recentPerformance: PerformanceMetrics) -> VideoDecoding? {
        
        guard recentPerformance.isDegraded else { return nil }
        
        // Check thermal throttling
        if systemState.thermalState == .critical {
            if current is VideoToolboxDecoder {
                return findSoftwareDecoder(from: [current])
            }
        }
        
        // Check CPU/GPU load
        if systemState.cpuUsage > 0.85 || systemState.gpuUsage > 0.90 {
            return selectMoreEfficientDecoder(current: current)
        }
        
        // Check battery state
        if systemState.batteryState == .charging && systemState.batteryLevel < 0.20 {
            return selectPowerEfficientDecoder(current: current)
        }
        
        return nil
    }
    
    // MARK: - Scoring

    private func calculateScore(for decoder: VideoDecoding,
                                track: VideoTrackInfo,
                                systemState: SystemState,
                                preference: DecoderPreference) -> DecoderScore {
        var score: Double = 0
        var reasons: [ScoreReason] = []

        // Codec support (0-30 points)
        if let codec = VideoCodec(rawValue: track.codec),
           decoder.capabilities.supportedCodecs.contains(codec) {
            score += 30
            reasons.append(.codecSupported)
        }

        // Hardware acceleration bonus (0-20 points)
        if decoder.capabilities.supportsHardwareAcceleration && systemState.isHardwareAvailable {
            score += 20
            reasons.append(.hardwareAvailable)
        }

        // Performance history (0-25 points)
        let perfScore = performanceScore(for: decoder)
        score += perfScore
        if perfScore > 15 { reasons.append(.goodPerformance) }

        // Thermal efficiency (0-15 points)
        if systemState.thermalState == .nominal {
            if decoder is VideoToolboxDecoder {
                score += 15
                reasons.append(.thermalEfficient)
            }
        }

        // Resolution support (0-10 points)
        let resolution = CGSize(width: track.width, height: track.height)
        if decoder.capabilities.maxResolution.width >= resolution.width &&
           decoder.capabilities.maxResolution.height >= resolution.height {
            score += 10
            reasons.append(.resolutionSupported)
        }

        // User preference tiebreak (0 or 5) — only one direction active at a time.
        switch (preference, decoder) {
        case (.preferHardware, is VideoToolboxDecoder),
             (.preferSoftware, is FFmpegSoftwareDecoder):
            score += 5
            reasons.append(.userPreference)
        default:
            break
        }

        return DecoderScore(score: score, reasons: reasons)
    }
    
    private func performanceScore(for decoder: VideoDecoding) -> Double {
        // Placeholder - would query performance monitor in production
        return 15.0
    }
    
    // MARK: - Helpers
    
    private func selectMoreEfficientDecoder(current: VideoDecoding) -> VideoDecoding? {
        if current is VideoToolboxDecoder {
            return findSoftwareDecoder(from: [current])
        }
        return findHardwareDecoder()
    }
    
    private func selectPowerEfficientDecoder(current: VideoDecoding) -> VideoDecoding? {
        if current is FFmpegSoftwareDecoder {
            return findHardwareDecoder()
        }
        return nil
    }
    
    private func findHardwareDecoder() -> VideoDecoding? {
        return VideoToolboxDecoder()
    }
    
    private func findSoftwareDecoder(from decoders: [VideoDecoding]) -> VideoDecoding? {
        // Reuse an existing software decoder if available
        if let existing = decoders.first(where: { $0 is FFmpegSoftwareDecoder }) {
            return existing
        }
        return FFmpegSoftwareDecoder()
    }
}
