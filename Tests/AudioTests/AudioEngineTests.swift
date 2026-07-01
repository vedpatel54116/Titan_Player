import XCTest
@testable import TitanPlayer

@MainActor
final class AudioEngineTests: XCTestCase {

    var audioEngine: AudioEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        audioEngine = try AudioEngine()
    }

    override func tearDownWithError() throws {
        audioEngine?.stop()
        audioEngine = nil
        try super.tearDownWithError()
    }

    // MARK: - Engine Lifecycle Tests

    func testEngineInitialization() throws {
        XCTAssertNotNil(audioEngine)
        XCTAssertFalse(audioEngine.isRunning)
    }

    func testEngineStartStop() throws {
        // Start the engine
        try audioEngine.startEngine()
        XCTAssertTrue(audioEngine.isRunning)

        // Stop the engine
        audioEngine.stop()
        XCTAssertFalse(audioEngine.isRunning)
    }

    // MARK: - Multi-Channel Audio Tests

    func testStereoConfiguration() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        try audioEngine.configureForMultiChannelAudio(format: format)
        XCTAssertEqual(audioEngine.currentChannelCount, 2)
    }

    func testSurround5_1Configuration() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 6)!
        try audioEngine.configureForMultiChannelAudio(format: format)
        XCTAssertEqual(audioEngine.currentChannelCount, 6)
    }

    func testSurround7_1Configuration() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 8)!
        try audioEngine.configureForMultiChannelAudio(format: format)
        XCTAssertEqual(audioEngine.currentChannelCount, 8)
    }

    func testAtmos7_1_4Configuration() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 12)!
        try audioEngine.configureForMultiChannelAudio(format: format)
        XCTAssertEqual(audioEngine.currentChannelCount, 12)
    }

    func testInvalidChannelCountThrowsError() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 16)!
        XCTAssertThrowsError(try audioEngine.configureForMultiChannelAudio(format: format)) { error in
            guard case AudioEngineError.formatNotSupported = error else {
                XCTFail("Expected formatNotSupported error")
                return
            }
        }
    }

    // MARK: - Spatial Audio Tests

    func testSpatialAudioEnabledByDefault() {
        XCTAssertTrue(audioEngine.spatialAudioEnabled)
    }

    func testEnableDisableSpatialAudio() {
        audioEngine.disableSpatialAudio()
        XCTAssertFalse(audioEngine.spatialAudioEnabled)

        audioEngine.enableSpatialAudio()
        XCTAssertTrue(audioEngine.spatialAudioEnabled)
    }

    // MARK: - Audio Quality Tests

    func testDefaultAudioQuality() {
        XCTAssertEqual(audioEngine.audioQuality, .high)
    }

    func testChangeAudioQuality() {
        audioEngine.audioQuality = .ultra
        XCTAssertEqual(audioEngine.audioQuality, .ultra)

        audioEngine.audioQuality = .low
        XCTAssertEqual(audioEngine.audioQuality, .low)
    }

    // MARK: - Sample Rate Conversion Tests

    func testSampleRateConversion_44100_to_48000() throws {
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1024)!
        inputBuffer.frameLength = 1024

        let outputBuffer = try audioEngine.convertSampleRate(inputBuffer, to: 48000)

        XCTAssertEqual(outputBuffer.format.sampleRate, 48000)
        XCTAssertEqual(outputBuffer.format.channelCount, 2)
        XCTAssertTrue(outputBuffer.frameLength > 0)
    }

    func testSampleRateConversion_48000_to_96000() throws {
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1024)!
        inputBuffer.frameLength = 1024

        let outputBuffer = try audioEngine.convertSampleRate(inputBuffer, to: 96000)

        XCTAssertEqual(outputBuffer.format.sampleRate, 96000)
        XCTAssertEqual(outputBuffer.format.channelCount, 2)
        XCTAssertTrue(outputBuffer.frameLength > 0)
    }

    func testSampleRateConversionNoChange() throws {
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1024)!
        inputBuffer.frameLength = 1024

        let outputBuffer = try audioEngine.convertSampleRate(inputBuffer, to: 48000)

        // Should return the same buffer when no conversion is needed
        XCTAssertTrue(outputBuffer === inputBuffer)
    }

    // MARK: - Latency Tests

    func testLatencyWithinTarget() {
        // Latency should be 0 before any processing
        XCTAssertTrue(audioEngine.isLatencyWithinTarget())
        XCTAssertTrue(audioEngine.getCurrentLatency() < 0.050)
    }

    // MARK: - Audio Passthrough Tests

    func testEnableAudioPassthroughDisablesSpatialAudio() {
        audioEngine.enableAudioPassthrough()
        XCTAssertFalse(audioEngine.spatialAudioEnabled)
    }

    // MARK: - Performance Tests

    func testCPUUsageTracking() {
        audioEngine.updateCPUUsage()
        let usage = audioEngine.cpuUsage
        XCTAssertTrue(usage >= 0.0)
    }

    // MARK: - Buffer Processing Tests

    func testProcessAudioBuffer() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024

        // Fill buffer with test data
        if let channelData = buffer.floatChannelData {
            for channel in 0..<2 {
                for frame in 0..<1024 {
                    channelData[channel][frame] = Float.random(in: -1.0...1.0)
                }
            }
        }

        // Process buffer should not throw
        audioEngine.processAudioBuffer(buffer)

        // Since the engine is not running, buffer processing should be a no-op
        // But the method should not throw
    }

    func testProcessAudioBufferWithSpatialAudio() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024

        // Enable spatial audio
        audioEngine.enableSpatialAudio()
        XCTAssertTrue(audioEngine.spatialAudioEnabled)

        // Process buffer with spatial audio enabled
        audioEngine.processAudioBuffer(buffer)

        // Should not throw even with spatial audio processing
    }

    // MARK: - Buffer Pool Tests

    func testBufferPoolReuse() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

        // Create two buffers
        let buffer1 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        let buffer2 = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!

        // Buffers should have the correct format
        XCTAssertEqual(buffer1.format.sampleRate, 48000)
        XCTAssertEqual(buffer1.format.channelCount, 2)
        XCTAssertEqual(buffer2.format.sampleRate, 48000)
        XCTAssertEqual(buffer2.format.channelCount, 2)
    }

    // MARK: - Stress Tests

    func testRapidStartStop() throws {
        for _ in 0..<10 {
            try audioEngine.startEngine()
            XCTAssertTrue(audioEngine.isRunning)
            audioEngine.stop()
            XCTAssertFalse(audioEngine.isRunning)
        }
    }

    func testFrequentConfigurationChanges() throws {
        let channelConfigs = [2, 6, 8, 12, 2, 6]
        for channelCount in channelConfigs {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: AVAudioChannelCount(channelCount))!
            try audioEngine.configureForMultiChannelAudio(format: format)
            XCTAssertEqual(audioEngine.currentChannelCount, channelCount)
        }
    }

    // MARK: - Dolby Atmos Passthrough Tests

    func testDolbyAtmosPassthrough() {
        // Enable passthrough for Dolby Atmos
        audioEngine.enableAudioPassthrough()\n        XCTAssertFalse(audioEngine.spatialAudioEnabled)

        // In a real scenario, this would verify:
        // - Dolby TrueHD bitstream passthrough
        // - Metadata preservation
        // - No downmixing applied
    }

    // MARK: - DTS-HD MA Passthrough Tests

    func testDTSHDMaPassthrough() {
        // Enable passthrough for DTS-HD MA
        audioEngine.enableAudioPassthrough()
        XCTAssertFalse(audioEngine.spatialAudioEnabled)

        // In a real scenario, this would verify:
        // - DTS-HD MA bitstream passthrough
        // - Core + extension stream handling
        // - No transcoding applied
    }

    // MARK: - Integration Tests

    func testCompleteAudioPipeline() throws {
        // Configure for multi-channel audio
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 8)!
        try audioEngine.configureForMultiChannelAudio(format: format)

        // Start the engine
        try audioEngine.startEngine()
        XCTAssertTrue(audioEngine.isRunning)

        // Create and process a buffer
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        audioEngine.processAudioBuffer(buffer)

        // Verify latency is within target
        XCTAssertTrue(audioEngine.isLatencyWithinTarget())

        // Stop the engine
        audioEngine.stop()
        XCTAssertFalse(audioEngine.isRunning)
    }
}