import Foundation
import os
import Combine

// MARK: - Decoder Health

/// Snapshot of decoder runtime state surfaced in the Decoder Health panel.
struct DecoderHealth: Sendable {
    let activeDecoder: String
    let fallbackCount: Int
    let lastErrorCode: Int?
    let pixelFormat: OSType?

    var pixelFormatDescription: String {
        guard let pixelFormat else { return "n/a" }
        let bytes = [
            UInt8((pixelFormat >> 24) & 0xFF),
            UInt8((pixelFormat >> 16) & 0xFF),
            UInt8((pixelFormat >> 8) & 0xFF),
            UInt8(pixelFormat & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", pixelFormat)
    }
}

// MARK: - Manager State

enum ManagerState: Sendable {
    case idle
    case decoding(VideoDecoding)
    case switching(from: VideoDecoding, to: VideoDecoding)
    case error(DecoderError)
}

// MARK: - Adaptive Decoder Manager

class AdaptiveDecoderManager: @unchecked Sendable {
    // Decoder instances
    private var hardwareDecoder: VideoToolboxDecoder?
    private var softwareDecoder: FFmpegSoftwareDecoder?
    private(set) var activeDecoder: VideoDecoding?
    
    // Selection intelligence
    private let decoderSelector: DecoderSelector
    private let performanceMonitor: PerformanceMonitor
    
    // State
    private(set) var currentState: ManagerState = .idle

    // User-driven decoder preference (set via PerformanceOptimizer / external code).
    private var preference: DecoderPreference = .neutral
    private let preferenceLock = OSAllocatedUnfairLock()

    // Use actor for thread-safe state management
    private let stateActor = DecoderStateActor()

    // Health / fallback tracking. These counters are mutated from `async`
    // contexts that can interleave, so they are protected by a single lock.
    private struct DecoderStats {
        var currentTrack: VideoTrackInfo?
        var hardwareFailureCount = 0
        var fallbackCount = 0
        var lastErrorCode: Int?
    }
    private let statsLock = OSAllocatedUnfairLock(initialState: DecoderStats())

    private let healthSubject = CurrentValueSubject<DecoderHealth, Never>(
        DecoderHealth(activeDecoder: "none", fallbackCount: 0, lastErrorCode: nil, pixelFormat: nil)
    )
    var decoderHealthPublisher: AnyPublisher<DecoderHealth, Never> { healthSubject.eraseToAnyPublisher() }

    private let logger = Logger(subsystem: "com.titanplayer", category: "Decoder")

    init() {
        self.decoderSelector = DecoderSelector()
        self.performanceMonitor = PerformanceMonitor()
    }

    // MARK: - Public API

    func forcePreference(_ preference: DecoderPreference?) {
        preferenceLock.withLock {
            self.preference = preference ?? .neutral
        }
    }

    func configure(for track: VideoTrackInfo) async throws {
        statsLock.withLock { $0.currentTrack = track }

        let availableDecoders = queryAvailableDecoders(for: track)

        let pref = preferenceLock.withLock { self.preference }

        let selection = try decoderSelector.selectDecoder(
            for: track,
            available: availableDecoders,
            systemState: performanceMonitor.currentSystemState,
            preference: pref
        )

        // Try the selected decoder
        do {
            try await selection.decoder.configure(for: track)
            await stateActor.setActiveDecoder(selection.decoder)
            await stateActor.setState(.decoding(selection.decoder))
            statsLock.withLock { $0.hardwareFailureCount = 0 }
            let decoderName = String(describing: type(of: selection.decoder))
            logger.info("Selected decoder: \(decoderName)")
            await publishHealth()
            return
        } catch {
            // If hardware failed, try software fallback
            guard let fallback = getFallbackDecoder(for: selection.decoder) else {
                throw PlaybackError.decodingFailed(error)
            }

            do {
                statsLock.withLock { $0.fallbackCount += 1 }
                try await fallback.configure(for: track)
                await stateActor.setActiveDecoder(fallback)
                await stateActor.setState(.decoding(fallback))
                let fallbackName = String(describing: type(of: fallback))
                logger.info("Fell back to: \(fallbackName)")
                await publishHealth()
                return
            } catch {
                // Both decoders failed
                logger.error("Both decoders failed: \(error.localizedDescription)")
                await stateActor.setState(.error(.softwareFailure))
                throw PlaybackError.decodingFailed(error)
            }
        }
    }
    
    func decode(_ packet: MediaPacket) async throws -> DecoderOutput {
        guard let decoder = await stateActor.getActiveDecoder() else {
            throw DecoderError.sessionNotConfigured
        }
        
        do {
            let output = try await decoder.decode(packet)

            // A successful decode clears any consecutive-hardware-failure streak.
            statsLock.withLock { $0.hardwareFailureCount = 0 }
            
            // Update performance metrics
            performanceMonitor.recordDecodeTiming(
                decoder: type(of: decoder),
                duration: packet.duration.seconds
            )
            
            // Check if we should switch decoders
            let shouldSwitch = decoderSelector.checkForSwitch(
                current: decoder,
                systemState: performanceMonitor.currentSystemState,
                recentPerformance: performanceMonitor.recentMetrics
            )
            
            if let switchTo = shouldSwitch {
                try await performSwitch(to: switchTo)
                guard let newDecoder = await stateActor.getActiveDecoder() else {
                    throw DecoderError.sessionNotConfigured
                }
                return try await newDecoder.decode(packet)
            }
            
            return output
            
        } catch {
            return try await handleDecodeError(error, packet: packet)
        }
    }
    
    func flush() async {
        let decoder = await stateActor.getActiveDecoder()
        await decoder?.flush()
    }
    
    func invalidate() async {
        await hardwareDecoder?.invalidate()
        await softwareDecoder?.invalidate()
        await stateActor.setActiveDecoder(nil)
        await stateActor.setState(.idle)
        performanceMonitor.reset()
        statsLock.withLock {
            $0.hardwareFailureCount = 0
            $0.fallbackCount = 0
            $0.lastErrorCode = nil
        }
        await publishHealth()
    }
    
    var activeDecoderType: String? {
        get async {
            await stateActor.getActiveDecoder().map { String(describing: type(of: $0)) }
        }
    }

    var selectedDecoderName: String? {
        get async {
            await stateActor.getActiveDecoder().map { String(describing: type(of: $0)) }
        }
    }
    
    // MARK: - Hot-Swap Support
    
    private func performSwitch(to newDecoder: VideoDecoding) async throws {
        guard let oldDecoder = await stateActor.getActiveDecoder() else { return }
        
        await stateActor.setState(.switching(from: oldDecoder, to: newDecoder))
        
        // Flush old decoder
        await oldDecoder.flush()
        
        // Configure new decoder if needed
        if case .idle = newDecoder.state, let track = statsLock.withLock({ $0.currentTrack }) {
            try await newDecoder.configure(for: track)
        }
        
        // Switch active decoder
        await stateActor.setActiveDecoder(newDecoder)
        await stateActor.setState(.decoding(newDecoder))
        
        // Record switch
        performanceMonitor.recordDecoderSwitch(
            from: type(of: oldDecoder),
            to: type(of: newDecoder)
        )
    }
    
    // MARK: - Error Handling
    
    private func handleDecodeError(_ error: Error, packet: MediaPacket) async throws -> DecoderOutput {
        recordLastError(error)

        guard let decoderError = error as? DecoderError else {
            throw error
        }
        
        // Consecutive hardware failures: keep retrying the hardware decoder for
        // up to 3 attempts, then abandon it for the software decoder so video
        // always keeps playing.
        if case .hardwareFailure = decoderError,
           let current = await stateActor.getActiveDecoder(),
           current is VideoToolboxDecoder {
            let failureCount = statsLock.withLock { stats in
                stats.hardwareFailureCount += 1
                return stats.hardwareFailureCount
            }
            if failureCount >= 3 {
                statsLock.withLock { $0.hardwareFailureCount = 0 }
                guard let fallback = getFallbackDecoder(for: current) else {
                    await stateActor.setState(.error(decoderError))
                    throw decoderError
                }
                statsLock.withLock { $0.fallbackCount += 1 }
                do {
                    try await performSwitch(to: fallback)
                } catch {
                    await stateActor.setState(.error(decoderError))
                    throw decoderError
                }
                guard let newDecoder = await stateActor.getActiveDecoder() else {
                    throw DecoderError.sessionNotConfigured
                }
                await publishHealth()
                return try await newDecoder.decode(packet)
            }
            // Fewer than 3: reset and retry the same hardware decoder once.
            await current.reset()
            return try await current.decode(packet)
        }
        
        switch decoderError.severity {
        case .transient:
            // Try fallback decoder
            guard let currentDecoder = await stateActor.getActiveDecoder(),
                  let fallback = getFallbackDecoder(for: currentDecoder) else {
                throw decoderError
            }
            statsLock.withLock { $0.fallbackCount += 1 }
            try await performSwitch(to: fallback)
            guard let newDecoder = await stateActor.getActiveDecoder() else {
                throw DecoderError.sessionNotConfigured
            }
            await publishHealth()
            return try await newDecoder.decode(packet)
            
        case .persistent:
            // Report to UI
            await stateActor.setState(.error(decoderError))
            throw decoderError
        }
    }
    
    private func recordLastError(_ error: Error) {
        statsLock.withLock { $0.lastErrorCode = (error as NSError).code }
        Task { [weak self] in await self?.publishHealth() }
    }

    private func publishHealth() async {
        let decoder = await stateActor.getActiveDecoder()
        let name = decoder.map { String(describing: type(of: $0)) } ?? "none"
        let pixelFormat = decoder?.negotiatedPixelFormat
        let (fallbackCount, lastErrorCode) = statsLock.withLock { ($0.fallbackCount, $0.lastErrorCode) }
        let health = DecoderHealth(
            activeDecoder: name,
            fallbackCount: fallbackCount,
            lastErrorCode: lastErrorCode,
            pixelFormat: pixelFormat
        )
        healthSubject.send(health)
    }
    
    private func getFallbackDecoder(for decoder: VideoDecoding) -> VideoDecoding? {
        if decoder is VideoToolboxDecoder {
            if softwareDecoder == nil {
                softwareDecoder = FFmpegSoftwareDecoder()
            }
            return softwareDecoder
        } else if decoder is FFmpegSoftwareDecoder {
            if hardwareDecoder == nil {
                hardwareDecoder = VideoToolboxDecoder()
            }
            return hardwareDecoder
        }
        return nil
    }
    
    private func queryAvailableDecoders(for track: VideoTrackInfo) -> [VideoDecoding] {
        var decoders: [VideoDecoding] = []
        
        // Hardware decoder
        if HardwareCapabilities.isCodecSupported(VideoCodec(rawValue: track.codec) ?? .h264) {
            if hardwareDecoder == nil {
                hardwareDecoder = VideoToolboxDecoder()
            }
            decoders.append(hardwareDecoder!)
        }
        
        // Software decoder (always available)
        if softwareDecoder == nil {
            softwareDecoder = FFmpegSoftwareDecoder()
        }
        decoders.append(softwareDecoder!)
        
        return decoders
    }
}

// MARK: - Actor for Thread-Safe State

private actor DecoderStateActor {
    private var activeDecoder: VideoDecoding?
    private var currentState: ManagerState = .idle
    
    func getActiveDecoder() -> VideoDecoding? {
        return activeDecoder
    }
    
    func setActiveDecoder(_ decoder: VideoDecoding?) {
        self.activeDecoder = decoder
    }
    
    func getState() -> ManagerState {
        return currentState
    }
    
    func setState(_ state: ManagerState) {
        self.currentState = state
    }
}
