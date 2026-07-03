import AVFAudio
import AudioToolbox
import Accelerate
import simd
import Combine
import os.log

/// Custom logger for audio system
private let audioLogger = Logger(subsystem: "com.titanplayer.audio", category: "AudioEngine")

/// Error types for the audio engine
enum AudioEngineError: Error {
    case notRunning
    case invalidFormat
    case bufferCreationFailed
    case engineNotInitialized
    case formatNotSupported
    case spatialAudioInitializationFailed
}

/// Audio quality settings
enum AudioQuality: String, CaseIterable {
    case low      // 44.1kHz, 16-bit
    case medium   // 48kHz, 24-bit
    case high     // 96kHz, 32-bit
    case ultra    // 192kHz, 32-bit
}

/// Head-related transfer function (HRTF) data for spatial audio
struct HRTFData {
    let leftEar: [Float]
    let rightEar: [Float]
    let sampleRate: Double
    let azimuth: Float
    let elevation: Float
}

/// Spatial audio configuration
struct SpatialAudioConfiguration {
    var headPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    var headOrientation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    var roomSize: Float = 1.0
    var reverbAmount: Float = 0.3
    var hrtfEnabled: Bool = true
}

/// Audio format information
struct AudioFormatInfo {
    let sampleRate: Double
    let channelCount: Int
    let bitDepth: Int
    let isSpatialAudio: Bool
    let channelLayout: AudioChannelLayout
}

/// Represents a spatial audio source position
struct AudioSourcePosition {
    let x: Float
    let y: Float
    let z: Float
}

/// Main audio engine class with spatial audio support
@MainActor
final class AudioEngine: ObservableObject {
    // MARK: - Published Properties
    @Published var spatialAudioEnabled: Bool = true
    @Published var audioQuality: AudioQuality = .high
    @Published var isRunning: Bool = false
    @Published var currentLatency: TimeInterval = 0
    @Published var cpuUsage: Double = 0

    // MARK: - Private Properties
    nonisolated(unsafe) private let engine = AVAudioEngine()
    nonisolated(unsafe) private var playerNode: AVAudioPlayerNode?
    nonisolated(unsafe) private var environmentNode: AVAudioEnvironmentNode?
    private let bufferPool = AudioBufferPool()
    private let coreAudioBridge: CoreAudioBridge

    nonisolated(unsafe) private var spatialConfig = SpatialAudioConfiguration()
    nonisolated(unsafe) private var hrtfData: [HRTFData] = []
    private var audioSources: [UUID: AudioSourcePosition] = [:]
    private var cancellables = Set<AnyCancellable>()

    // Processing state
    private var processingQueue: DispatchQueue
    private let audioQueue = DispatchQueue(label: "com.titanplayer.audio.graph", qos: .userInteractive)
    private var isProcessing: Bool = false
    private var startTime: TimeInterval = 0
    nonisolated(unsafe) private var isReconfiguringSpatialAudio: Bool = false

    // Format tracking
    private var currentFormat: AVAudioFormat?
    private var targetSampleRate: Double = 48000
    private var currentChannelCount: Int = 2

    // MARK: - Initialization

    init() throws {
        processingQueue = DispatchQueue(label: "com.titanplayer.audio.processing", qos: .userInteractive)
        coreAudioBridge = try CoreAudioBridge()
        try setupAudioGraph()
    }

    // MARK: - Audio Graph Setup

    private func setupAudioGraph() throws {
        // Create and configure audio nodes
        playerNode = AVAudioPlayerNode()
        environmentNode = AVAudioEnvironmentNode()

        guard let playerNode = playerNode, let environmentNode = environmentNode else {
            throw AudioEngineError.engineNotInitialized
        }

        // Attach nodes to engine
        engine.attach(playerNode)
        engine.attach(environmentNode)

        // Configure optimal format for spatial audio
        let format = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: AVAudioChannelCount(currentChannelCount))!

        // Connect nodes: player -> environment -> mixer -> output
        engine.connect(playerNode, to: environmentNode, format: format)
        engine.connect(environmentNode, to: engine.mainMixerNode, format: format)

        // Configure environment node for spatial audio
        configureEnvironmentNode(environmentNode)

        // Configure main mixer
        engine.mainMixerNode.outputVolume = 1.0

        audioLogger.info("Audio graph initialized with spatial audio support")
    }

    private func configureEnvironmentNode(_ node: AVAudioEnvironmentNode) {
        // Configure reverb for room simulation
        node.reverbParameters.enable = true
        node.reverbParameters.level = 0.3
        node.reverbParameters.filterParameters.frequency = 1000.0
        node.reverbParameters.filterParameters.bandwidth = 1.0
        node.reverbParameters.filterParameters.gain = 0.0

        // Set listener position and orientation
        node.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        node.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)

        // Configure distance attenuation
        node.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        node.distanceAttenuationParameters.referenceDistance = 1.0
        node.distanceAttenuationParameters.maximumDistance = 100.0

        audioLogger.debug("Environment node configured for spatial audio")
    }

    // MARK: - Engine Control

    func startEngine() throws {
        guard !isRunning else { return }

        // Prepare engine before starting to prevent glitches
        engine.prepare()
        try engine.start()
        try coreAudioBridge.start()
        playerNode?.play()
        isRunning = true
        startTime = Date().timeIntervalSince1970

        audioLogger.info("Audio engine started")
    }

    func stop() {
        guard isRunning else { return }

        playerNode?.stop()
        engine.stop()
        coreAudioBridge.stop()
        isRunning = false

        audioLogger.info("Audio engine stopped")
    }

    // MARK: - Audio Processing

    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning else { return }

        let startProcessingTime = Date().timeIntervalSince1970

        // Get buffer from pool to avoid allocations
        let processingBuffer = bufferPool.dequeueBuffer(for: buffer.format, frameCount: buffer.frameLength)
        processingBuffer.frameLength = buffer.frameLength

        // Copy input to processing buffer
        copyBuffer(from: buffer, to: processingBuffer)

        // Apply spatial audio effects on the audio queue to avoid graph reconfiguration conflicts
        let spatialEnabled = spatialAudioEnabled
        if spatialEnabled {
            audioQueue.sync { [weak self] in
                guard let self = self else { return }
                self.applySpatialAudio(to: processingBuffer)
            }
        }

        // Apply volume scaling based on quality settings
        applyVolumeScaling(to: processingBuffer)

        // Apply equalization if needed
        applyEqualization(to: processingBuffer)

        // Schedule processed buffer for playback
        playerNode?.scheduleBuffer(processingBuffer, completionHandler: nil)

        // Calculate and update latency
        let endProcessingTime = Date().timeIntervalSince1970
        currentLatency = endProcessingTime - startProcessingTime

        // Return buffer to pool
        bufferPool.enqueueBuffer(processingBuffer)
    }

    private func copyBuffer(from source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) {
        guard source.format == destination.format else { return }

        let frameCount = Int(source.frameLength)
        let channelCount = Int(source.format.channelCount)

        for channel in 0..<channelCount {
            if let sourceData = source.floatChannelData?[channel],
               let destData = destination.floatChannelData?[channel] {
                memcpy(destData, sourceData, frameCount * MemoryLayout<Float>.size)
            }
        }
    }

    // MARK: - Spatial Audio

    private func applySpatialAudio(to buffer: AVAudioPCMBuffer) {
        guard spatialAudioEnabled, let environmentNode = environmentNode else { return }

        // Update listener position and orientation
        environmentNode.listenerPosition = AVAudio3DPoint(
            x: spatialConfig.headPosition.x,
            y: spatialConfig.headPosition.y,
            z: spatialConfig.headPosition.z
        )

        // Convert quaternion to angular orientation
        let orientation = quaternionToEuler(spatialConfig.headOrientation)
        environmentNode.listenerAngularOrientation = orientation

        // Apply HRTF processing if enabled
        if spatialConfig.hrtfEnabled {
            applyHRTF(to: buffer)
        }

        // Apply room simulation
        applyRoomSimulation(to: buffer)
    }

    private func applyHRTF(to buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        guard let leftChannel = buffer.floatChannelData?[0],
              let rightChannel = buffer.floatChannelData?[1] else { return }

        let headRadius: Float = 0.0875
        let speedOfSound: Float = 343.0
        let azimuth = atan2(spatialConfig.headPosition.x, spatialConfig.headPosition.z)
        let absAzimuth = abs(azimuth)
        let normalizedAzimuth = min(absAzimuth / (Float.pi / 2), 1.0)
        let itdMs = Double((headRadius / speedOfSound) * (absAzimuth + sin(absAzimuth)) * 1000)
        let itdSamples = itdMs * sampleRate / 1000.0
        let headShadowCutoff: Float = 4000.0 - normalizedAzimuth * 3200.0
        let rc: Float = 1.0 / (2.0 * .pi * headShadowCutoff)
        let alpha: Float = Float(1.0 / (sampleRate * Double(rc) + 1.0))

        var leftFilter: Float = 0
        var rightFilter: Float = 0

        for i in 0..<frameCount {
            let delayWholeL = Int(floor(itdSamples * 0.5))
            let delayFracL = Float(itdSamples * 0.5 - Double(delayWholeL))
            var leftSample: Float = 0
            let srcIdxL = i - delayWholeL
            if srcIdxL >= 1 && srcIdxL < frameCount {
                leftSample = leftChannel[srcIdxL] * (1 - delayFracL) + leftChannel[srcIdxL - 1] * delayFracL
            } else if srcIdxL >= 0 && srcIdxL < frameCount {
                leftSample = leftChannel[srcIdxL]
            }
            leftFilter = alpha * leftSample + (1 - alpha) * leftFilter
            leftChannel[i] = leftFilter

            let delayWholeR = Int(floor(-itdSamples * 0.5))
            let delayFracR = Float(-itdSamples * 0.5 - Double(delayWholeR))
            var rightSample: Float = 0
            let srcIdxR = i - delayWholeR
            if srcIdxR >= 1 && srcIdxR < frameCount {
                rightSample = rightChannel[srcIdxR] * (1 - delayFracR) + rightChannel[srcIdxR - 1] * delayFracR
            } else if srcIdxR >= 0 && srcIdxR < frameCount {
                rightSample = rightChannel[srcIdxR]
            }
            rightFilter = alpha * rightSample + (1 - alpha) * rightFilter
            rightChannel[i] = rightFilter
        }
    }

    private func applyRoomSimulation(to buffer: AVAudioPCMBuffer) {
        // Room simulation is handled by the AVAudioEnvironmentNode
        // This method can be extended for custom room effects
        guard let environmentNode = environmentNode else { return }

        environmentNode.reverbParameters.level = spatialConfig.reverbAmount * spatialConfig.roomSize
    }

    private func applyVolumeScaling(to buffer: AVAudioPCMBuffer) {
        let volume: Float
        switch audioQuality {
        case .low:
            volume = 0.8
        case .medium:
            volume = 0.9
        case .high:
            volume = 1.0
        case .ultra:
            volume = 1.0
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)

        for channel in 0..<channelCount {
            if let channelData = buffer.floatChannelData?[channel] {
                var scaledVolume = volume
                vDSP_vsmul(channelData, 1, &scaledVolume, channelData, 1, vDSP_Length(frameCount))
            }
        }
    }

    private func applyEqualization(to buffer: AVAudioPCMBuffer) {
        // Apply basic equalization based on quality settings
        // This is a placeholder for more sophisticated EQ processing
    }

    // MARK: - Spatial Audio Configuration

    func enableSpatialAudio() {
        guard !spatialAudioEnabled else { return }

        // Set flag immediately for UI consistency
        spatialAudioEnabled = true
        isReconfiguringSpatialAudio = true

        // Dispatch graph reconfiguration to dedicated audio queue
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            // Configure head tracking if available
            self.setupHeadTracking()

            // Set up HRTF data
            self.setupHRTF()

            // Configure reverb based on room characteristics
            self.configureReverb()

            // Prepare engine to prevent glitches before any graph changes
            self.engine.prepare()

            self.isReconfiguringSpatialAudio = false
            audioLogger.info("Spatial audio enabled")
        }
    }

    func disableSpatialAudio() {
        // Set flag immediately for UI consistency
        spatialAudioEnabled = false
        isReconfiguringSpatialAudio = true

        // Dispatch graph reconfiguration to dedicated audio queue
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            // Prepare engine to prevent glitches before any graph changes
            self.engine.prepare()

            self.isReconfiguringSpatialAudio = false
            audioLogger.info("Spatial audio disabled")
        }
    }

    nonisolated private func setupHeadTracking() {
        // This would integrate with head tracking hardware or software
        // For now, we set up a basic orientation that can be updated
        spatialConfig.headPosition = SIMD3<Float>(0, 0, 0)
        spatialConfig.headOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

        audioLogger.debug("Head tracking configured")
    }

    nonisolated private func setupHRTF() {
        // Load HRTF data from bundle or generate default
        // This is a simplified implementation
        hrtfData = loadDefaultHRTF()
        audioLogger.debug("HRTF data loaded: \(self.hrtfData.count) positions")
    }

    nonisolated private func loadDefaultHRTF() -> [HRTFData] {
        var hrtf: [HRTFData] = []
        let headRadius: Float = 0.0875
        let speedOfSound: Float = 343.0
        let sampleRate: Double = 48000
        let filterLength = 64

        for angle in stride(from: -180.0, through: 180.0, by: 5.0) {
            let azimuth = Float(angle * .pi / 180.0)
            let absAzimuth = abs(azimuth)
            let itdMs = Double((headRadius / speedOfSound) * (absAzimuth + sin(absAzimuth)) * 1000)
            let itdSamples = Int(itdMs * sampleRate / 1000.0)

            var leftIR = [Float](repeating: 0, count: filterLength)
            var rightIR = [Float](repeating: 0, count: filterLength)

            let delayL = max(0, itdSamples)
            let delayR = max(0, -itdSamples)

            if delayL < filterLength { leftIR[delayL] = 0.8 }
            if delayR < filterLength { rightIR[delayR] = 0.8 }

            let normalizedAzimuth = min(absAzimuth / (.pi / 2), 1.0)
            let cutoff: Float = 4000.0 - normalizedAzimuth * 3200.0
            let rc: Float = 1.0 / (2.0 * .pi * cutoff)
            let alpha: Float = Float(1.0 / (sampleRate * Double(rc) + 1.0))
            var leftState: Float = 0
            var rightState: Float = 0
            for j in 0..<filterLength {
                leftState = alpha * leftIR[j] + (1 - alpha) * leftState
                leftIR[j] = leftState
                rightState = alpha * rightIR[j] + (1 - alpha) * rightState
                rightIR[j] = rightState
            }

            let hrtfEntry = HRTFData(
                leftEar: leftIR,
                rightEar: rightIR,
                sampleRate: sampleRate,
                azimuth: azimuth,
                elevation: 0.0
            )
            hrtf.append(hrtfEntry)
        }

        return hrtf
    }

    nonisolated private func configureReverb() {
        guard let environmentNode = environmentNode else { return }

        environmentNode.reverbParameters.enable = true
        environmentNode.reverbParameters.level = spatialConfig.reverbAmount
        environmentNode.reverbParameters.filterParameters.frequency = 1000.0
        environmentNode.reverbParameters.filterParameters.bandwidth = 1.0
        environmentNode.reverbParameters.filterParameters.gain = 0.0

        audioLogger.debug("Reverb configured with level: \(self.spatialConfig.reverbAmount)")
    }

    // MARK: - Multi-Channel Audio Support

    func configureForMultiChannelAudio(format: AVAudioFormat) throws {
        let channelCount = Int(format.channelCount)

        // Validate channel count
        guard channelCount >= 1 && channelCount <= 12 else {
            throw AudioEngineError.formatNotSupported
        }

        currentChannelCount = channelCount
        currentFormat = format

        // Reconfigure audio graph for multi-channel
        try reconfigureAudioGraph(for: format)

        // Determine audio format from channel count
        let audioFormat: TelemetryAudioFormat
        switch channelCount {
        case 1, 2: audioFormat = .stereo
        case 3...6: audioFormat = .surround5_1
        case 7...12: audioFormat = .atmos
        default: audioFormat = .stereo
        }

        TelemetryManager.shared.record(.audioFormatUsed(
            format: audioFormat,
            sampleRate: Int(format.sampleRate),
            bitDepth: 32 // AVAudioFormat typically uses 32-bit float
        ))

        audioLogger.info("Configured for \(channelCount)-channel audio")
    }

    private func reconfigureAudioGraph(for format: AVAudioFormat) throws {
        // Synchronize graph mutations on the dedicated audio queue
        let semaphore = DispatchSemaphore(value: 0)
        var graphError: Error?

        audioQueue.sync { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }

            do {
                self.engine.stop()

                // Disconnect existing nodes
                if let playerNode = self.playerNode {
                    self.engine.disconnectNodeOutput(playerNode)
                }
                if let environmentNode = self.environmentNode {
                    self.engine.disconnectNodeOutput(environmentNode)
                }

                // Reconnect with new format
                self.engine.connect(self.playerNode!, to: self.environmentNode!, format: format)
                self.engine.connect(self.environmentNode!, to: self.engine.mainMixerNode, format: format)

                // Prepare engine before starting to prevent glitches
                self.engine.prepare()

                try self.engine.start()

                audioLogger.debug("Audio graph reconfigured for format: \(format)")
            } catch {
                graphError = error
            }

            semaphore.signal()
        }

        semaphore.wait()

        if let error = graphError {
            throw error
        }
    }

    // MARK: - Sample Rate Conversion

    func convertSampleRate(_ buffer: AVAudioPCMBuffer, to targetSampleRate: Double) throws -> AVAudioPCMBuffer {
        let sourceSampleRate = buffer.format.sampleRate
        guard sourceSampleRate != targetSampleRate else { return buffer }

        // Use Core Audio's built-in resampler
        let outputFormat = AVAudioFormat(commonFormat: buffer.format.commonFormat,
                                          sampleRate: targetSampleRate,
                                          channels: buffer.format.channelCount,
                                          interleaved: buffer.format.isInterleaved)!

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * targetSampleRate / sourceSampleRate))!

        // Perform format conversion on the audio queue to avoid conflicts with graph mutations
        audioQueue.sync { [weak self] in
            guard let _ = self else { return }

            // High-quality resampling using vDSP
            let ratio = targetSampleRate / sourceSampleRate
            let inputFrameCount = Int(buffer.frameLength)
            let outputFrameCount = Int(outputBuffer.frameCapacity)

            for channel in 0..<Int(buffer.format.channelCount) {
                if let inputData = buffer.floatChannelData?[channel],
                   let outputData = outputBuffer.floatChannelData?[channel] {
                    // Simple linear interpolation for now
                    // In production, use higher quality resampling (e.g., SoX, Secret Rabbit Code)
                    for i in 0..<outputFrameCount {
                        let sourceIndex = Double(i) / ratio
                        let index1 = Int(sourceIndex)
                        let index2 = min(index1 + 1, inputFrameCount - 1)
                        let fraction = Float(sourceIndex - Double(index1))

                        let sample1 = inputData[index1]
                        let sample2 = inputData[index2]
                        outputData[i] = sample1 + (sample2 - sample1) * fraction
                    }
                }
            }

            outputBuffer.frameLength = AVAudioFrameCount(outputFrameCount)
        }

        return outputBuffer
    }

    // MARK: - Latency Management

    func getCurrentLatency() -> TimeInterval {
        return currentLatency
    }

    func isLatencyWithinTarget() -> Bool {
        return currentLatency < 0.050 // 50ms target
    }

    // MARK: - CPU Usage Monitoring

    func updateCPUUsage() {
        // Calculate CPU usage based on processing time
        let processingTime = currentLatency
        let bufferTime = Double(currentFormat?.sampleRate ?? 48000) * 0.01 // 10ms buffer
        cpuUsage = processingTime / bufferTime

        // Log if CPU usage is too high
        if cpuUsage > 0.03 { // 3% target
            audioLogger.warning("High CPU usage detected: \(self.cpuUsage * 100)%")
        }
    }

    // MARK: - Audio Passthrough

    func enableAudioPassthrough() {
        // Enable bit-perfect passthrough for Dolby TrueHD, DTS-HD MA
        // This bypasses all processing for compatible formats
        spatialAudioEnabled = false
        audioLogger.info("Audio passthrough enabled")
    }

    // MARK: - Performance adaptation seam

    private(set) var currentComplexityMode: AudioMode = .full

    func setComplexityMode(_ mode: AudioMode) {
        currentComplexityMode = mode
        switch mode {
        case .full:
            spatialAudioEnabled = true
            spatialConfig.hrtfEnabled = true
        case .simplified:
            spatialAudioEnabled = false
            spatialConfig.hrtfEnabled = false
        }
        audioLogger.info("AudioEngine complexity mode: \(mode == .full ? "full" : "simplified")")
    }

    // MARK: - Helper Methods

    private func quaternionToEuler(_ quaternion: simd_quatf) -> AVAudio3DAngularOrientation {
        let v = quaternion.vector

        let heading = atan2(2.0 * (v.w * v.y + v.x * v.z),
                            1.0 - 2.0 * (v.y * v.y + v.x * v.x))

        let pitch = asin(2.0 * (v.w * v.x - v.z * v.y))

        let roll = atan2(2.0 * (v.w * v.z + v.x * v.y),
                         1.0 - 2.0 * (v.x * v.x + v.y * v.y))

        let degrees = 180.0 / Float.pi
        return AVAudio3DAngularOrientation(
            yaw: Float(heading) * degrees,
            pitch: Float(pitch) * degrees,
            roll: Float(roll) * degrees
        )
    }

    // MARK: - Cleanup

    deinit {
        playerNode?.stop()
        engine.stop()
        coreAudioBridge.stop()
    }
}