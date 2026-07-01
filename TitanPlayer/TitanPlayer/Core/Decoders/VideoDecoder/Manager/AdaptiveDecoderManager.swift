import Foundation
import os

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
    private var currentTrack: VideoTrackInfo?

    // User-driven decoder preference (set via PerformanceOptimizer / external code).
    private var preference: DecoderPreference = .neutral
    private let preferenceLock = NSLock()

    // Use actor for thread-safe state management
    private let stateActor = DecoderStateActor()

    private let logger = Logger(subsystem: "com.titanplayer", category: "Decoder")

    init() {
        self.decoderSelector = DecoderSelector()
        self.performanceMonitor = PerformanceMonitor()
    }

    // MARK: - Public API

    func forcePreference(_ preference: DecoderPreference?) {
        preferenceLock.lock()
        self.preference = preference ?? .neutral
        preferenceLock.unlock()
    }

    func configure(for track: VideoTrackInfo) async throws {
        currentTrack = track

        let availableDecoders = queryAvailableDecoders(for: track)

        preferenceLock.lock()
        let pref = self.preference
        preferenceLock.unlock()

        let selection = decoderSelector.selectDecoder(
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
            let decoderName = String(describing: type(of: selection.decoder))
            logger.info("Selected decoder: \(decoderName)")
            return
        } catch {
            // If hardware failed, try software fallback
            guard let fallback = getFallbackDecoder(for: selection.decoder) else {
                throw PlaybackError.decodingFailed(error)
            }

            do {
                try await fallback.configure(for: track)
                await stateActor.setActiveDecoder(fallback)
                await stateActor.setState(.decoding(fallback))
                let fallbackName = String(describing: type(of: fallback))
                logger.info("Fell back to: \(fallbackName)")
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
        if case .idle = newDecoder.state, let track = currentTrack {
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
        guard let decoderError = error as? DecoderError else {
            throw error
        }
        
        switch decoderError.severity {
        case .transient:
            // Try fallback decoder
            guard let currentDecoder = await stateActor.getActiveDecoder(),
                  let fallback = getFallbackDecoder(for: currentDecoder) else {
                throw decoderError
            }
            
            try await performSwitch(to: fallback)
            guard let newDecoder = await stateActor.getActiveDecoder() else {
                throw DecoderError.sessionNotConfigured
            }
            return try await newDecoder.decode(packet)
            
        case .persistent:
            // Report to UI
            await stateActor.setState(.error(decoderError))
            throw decoderError
        }
    }
    
    private func getFallbackDecoder(for decoder: VideoDecoding) -> VideoDecoding? {
        if decoder is VideoToolboxDecoder {
            return softwareDecoder ?? FFmpegSoftwareDecoder()
        } else if decoder is FFmpegSoftwareDecoder {
            return hardwareDecoder ?? VideoToolboxDecoder()
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
