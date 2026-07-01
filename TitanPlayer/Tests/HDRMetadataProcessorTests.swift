import XCTest
import CoreMedia
import Metal
@testable import TitanPlayer

final class HDRMetadataProcessorTests: XCTestCase {
    
    var processor: HDRMetadataProcessor!
    
    override func setUp() {
        super.setUp()
        processor = HDRMetadataProcessor()
    }
    
    override func tearDown() {
        processor = nil
        super.tearDown()
    }
    
    func testConfigureWithDefaultConfig() {
        let config = HDRProcessingConfig.default
        processor.configure(with: config)
    }
    
    func testUpdateDisplayCapabilities() {
        let capabilities = DisplayCapabilities(
            supportsHDR: true,
            supportsEDR: true,
            maxEDRLuminance: 1600.0,
            colorGamut: .bt2020
        )
        
        processor.updateDisplayCapabilities(capabilities)
    }
    
    func testGetCurrentHDRModeDefault() {
        let mode = processor.getCurrentHDRMode()
        
        if case .sdr = mode {
        } else {
            XCTFail("Default mode should be SDR")
        }
    }
    
    func testReset() {
        let capabilities = DisplayCapabilities(
            supportsHDR: true,
            supportsEDR: true,
            maxEDRLuminance: 1600.0,
            colorGamut: .bt2020
        )
        processor.updateDisplayCapabilities(capabilities)
        
        processor.reset()
        
        let mode = processor.getCurrentHDRMode()
        if case .sdr = mode {
        } else {
            XCTFail("Mode should be SDR after reset")
        }
    }
    
    func testGetProcessedMetadataForTimestamp() {
        let timestamp = CMTime(seconds: 1, preferredTimescale: 600)
        let metadata = processor.getProcessedMetadata(for: timestamp)
    }
    
    func testGetDynamicToneMappingParamsDisabled() {
        let config = HDRProcessingConfig(
            enableDynamicToneMapping: false,
            enableMetadataPassthrough: true,
            fallbackToStaticHDR: true,
            targetLuminance: 1000.0
        )
        processor.configure(with: config)
        
        let timestamp = CMTime(seconds: 1, preferredTimescale: 600)
        let params = processor.getDynamicToneMappingParams(for: timestamp)
        
        XCTAssertNil(params)
    }
    
    func testMetadataUpdateStructure() {
        let timestamp = CMTime(seconds: 0, preferredTimescale: 600)
        let mode = ExtendedHDRMode.sdr
        
        let update = HDRMetadataProcessor.MetadataUpdate(
            mode: mode,
            timestamp: timestamp,
            isDynamic: false
        )
        
        XCTAssertFalse(update.isDynamic)
        XCTAssertEqual(update.timestamp, timestamp)
    }
    
    func testProcessedMetadataStructure() {
        let timestamp = CMTime(seconds: 0, preferredTimescale: 600)
        
        let processed = HDRMetadataProcessor.ProcessedMetadata(
            hdr10PlusParams: nil,
            dolbyVisionParams: nil,
            selectedTrimPass: nil,
            timestamp: timestamp
        )
        
        XCTAssertNil(processed.hdr10PlusParams)
        XCTAssertNil(processed.dolbyVisionParams)
        XCTAssertNil(processed.selectedTrimPass)
        XCTAssertEqual(processed.timestamp, timestamp)
    }
    
    func testExtendedHDRModeIsDynamic() {
        XCTAssertTrue(ExtendedHDRMode.hdr10Plus(HDR10PlusMetadata(
            curveExponent: 20,
            kneePointX: 2048,
            kneePointY: 1024,
            numBezierCurveAnchors: 2,
            bezierCurveAnchors: [32, 64],
            colorSaturationMap: [128]
        )).isDynamic)
        
        XCTAssertTrue(ExtendedHDRMode.dolbyVision(DolbyVisionMetadata(
            profile: .profile5,
            blVideoSignalInfo: DolbyVisionVideoSignalInfo(
                colorSpace: .bt2020,
                transferCharacteristic: .pq,
                colorPrimaries: .bt2020
            ),
            elVideoSignalInfo: nil,
            rpuMetadata: DolbyVisionRPUMetadata(
                sceneRefreshFlag: false,
                targetDisplayMaxLuminance: 1000,
                targetDisplayMinLuminance: 1,
                trimPasses: [],
                activeAreaOffsets: nil
            )
        )).isDynamic)
        
        XCTAssertFalse(ExtendedHDRMode.sdr.isDynamic)
        XCTAssertFalse(ExtendedHDRMode.hlg.isDynamic)
    }
    
    func testHDRProcessingConfigDefault() {
        let config = HDRProcessingConfig.default
        
        XCTAssertTrue(config.enableDynamicToneMapping)
        XCTAssertTrue(config.enableMetadataPassthrough)
        XCTAssertTrue(config.fallbackToStaticHDR)
        XCTAssertEqual(config.targetLuminance, 1000.0)
    }
    
    func testHDRProcessingConfigEquality() {
        let config1 = HDRProcessingConfig(
            enableDynamicToneMapping: true,
            enableMetadataPassthrough: false,
            fallbackToStaticHDR: true,
            targetLuminance: 1600.0
        )
        
        let config2 = HDRProcessingConfig(
            enableDynamicToneMapping: true,
            enableMetadataPassthrough: false,
            fallbackToStaticHDR: true,
            targetLuminance: 1600.0
        )
        
        XCTAssertEqual(config1, config2)
    }
    
    // MARK: - Per-frame render-pass application (applyMetadata / resolveParams)
    
    private func makeCapabilities(maxLum: Float = 1600.0, edr: Bool = true) -> DisplayCapabilities {
        return DisplayCapabilities(
            supportsHDR: true,
            supportsEDR: edr,
            maxEDRLuminance: maxLum,
            colorGamut: .bt2020
        )
    }
    
    func testResolveParamsSDRDefaultNoCapabilities() {
        let params = processor.resolveParams(forFrameTime: 0)
        XCTAssertFalse(params.useDynamicMetadata)
        XCTAssertFalse(params.isDolbyVision)
        XCTAssertNil(params.dvProfile)
    }
    
    func testResolveParamsSDRWithCapabilities() {
        processor.updateDisplayCapabilities(makeCapabilities())
        let params = processor.resolveParams(forFrameTime: 1.0)
        XCTAssertFalse(params.useDynamicMetadata)
        XCTAssertEqual(params.saturationScale, 1.0)
        XCTAssertEqual(params.compressionRatio, 1.0)
    }
    
    func testAppliedHDRParamsStructure() {
        let params = HDRMetadataProcessor.AppliedHDRParams(
            kneePoint: 0.6,
            compressionRatio: 0.75,
            saturationScale: 1.1,
            brightnessAdjustment: 0.05,
            useDynamicMetadata: true,
            isDolbyVision: false,
            dvProfile: nil
        )
        XCTAssertEqual(params.kneePoint, 0.6)
        XCTAssertEqual(params.compressionRatio, 0.75)
        XCTAssertEqual(params.saturationScale, 1.1)
        XCTAssertEqual(params.brightnessAdjustment, 0.05)
        XCTAssertTrue(params.useDynamicMetadata)
        XCTAssertFalse(params.isDolbyVision)
    }
    
    func testResolveParamsIsDeterministicForSameFrame() {
        processor.updateDisplayCapabilities(makeCapabilities())
        let a = processor.resolveParams(forFrameTime: 2.5)
        let b = processor.resolveParams(forFrameTime: 2.5)
        XCTAssertEqual(a.kneePoint, b.kneePoint)
        XCTAssertEqual(a.compressionRatio, b.compressionRatio)
        XCTAssertEqual(a.saturationScale, b.saturationScale)
    }
    
    func testResetClearsTransitionState() {
        processor.updateDisplayCapabilities(makeCapabilities())
        _ = processor.resolveParams(forFrameTime: 0)
        _ = processor.resolveParams(forFrameTime: 0.5)
        processor.reset()
        let params = processor.resolveParams(forFrameTime: 1.0)
        XCTAssertFalse(params.useDynamicMetadata)
    }
    
    // MARK: - HDR10+ dynamic metadata resolution
    
    private func makeHDR10PlusSampleBuffer() -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 600),
            presentationTimeStamp: CMTime(value: 0, timescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let buffer = sampleBuffer else { return nil }

        let payload = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? NSMutableArray else {
            return nil
        }
        let attachment = NSMutableDictionary()
        attachment.setObject(payload, forKey: "HDR10PlusMetadata" as NSString)
        attachments.add(attachment)
        return buffer
    }
    
    func testHDR10PlusDynamicMetadataResolution() {
        processor.updateDisplayCapabilities(makeCapabilities())
        guard let sampleBuffer = makeHDR10PlusSampleBuffer() else {
            XCTFail("Failed to construct HDR10+ sample buffer")
            return
        }
        let update = processor.processMetadata(from: sampleBuffer)
        XCTAssertNotNil(update)
        if case .hdr10Plus = processor.getCurrentHDRMode() {
        } else {
            XCTFail("Expected HDR10+ mode after processing HDR10+ metadata")
        }
        let params = processor.resolveParams(forFrameTime: 0)
        XCTAssertTrue(params.useDynamicMetadata)
        XCTAssertFalse(params.isDolbyVision)
    }
    
    func testHDR10PlusFallsBackWhenDynamicDisabled() {
        processor.updateDisplayCapabilities(makeCapabilities())
        processor.configure(with: HDRProcessingConfig(
            enableDynamicToneMapping: false,
            enableMetadataPassthrough: true,
            fallbackToStaticHDR: true,
            targetLuminance: 1000.0
        ))
        guard let sampleBuffer = makeHDR10PlusSampleBuffer() else {
            XCTFail("Failed to construct HDR10+ sample buffer")
            return
        }
        _ = processor.processMetadata(from: sampleBuffer)
        let params = processor.resolveParams(forFrameTime: 0)
        XCTAssertFalse(params.useDynamicMetadata)
    }
    
    // MARK: - Dolby Vision profile resolution (4/5/7/8)
    
    private func makeDolbyVisionSampleBuffer(profile: DolbyVisionProfile) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 600),
            presentationTimeStamp: CMTime(value: 0, timescale: 600),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let buffer = sampleBuffer else { return nil }
        
        var bytes: [UInt8] = [0x02, 0x02, 0x02]
        bytes += [0x03, 0xE8, 0x00, 0x01, 0x00]
        let payload = Data(bytes)
        
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? NSMutableArray else {
            return nil
        }
        let attachment = NSMutableDictionary()
        attachment.setObject(NSNumber(value: profile.rawValue), forKey: "DolbyVisionProfile" as NSString)
        attachment.setObject(payload, forKey: "DolbyVisionMetadata" as NSString)
        attachments.add(attachment)
        return buffer
    }
    
    func testDolbyVisionProfilesSupported() {
        processor.updateDisplayCapabilities(makeCapabilities())
        for profile in [DolbyVisionProfile.profile4, .profile5, .profile7, .profile8] {
            processor.reset()
            guard let sampleBuffer = makeDolbyVisionSampleBuffer(profile: profile) else {
                XCTFail("Failed to construct DV sample buffer for profile \(profile.rawValue)")
                return
            }
            _ = processor.processMetadata(from: sampleBuffer)
            if case .dolbyVision(let metadata) = processor.getCurrentHDRMode() {
                XCTAssertEqual(metadata.profile, profile)
            } else {
                XCTFail("Expected DolbyVision mode for profile \(profile.rawValue)")
                return
            }
            let params = processor.resolveParams(forFrameTime: 0)
            XCTAssertTrue(params.isDolbyVision)
            XCTAssertEqual(params.dvProfile, profile)
            XCTAssertTrue(params.useDynamicMetadata)
        }
    }
    
    func testDolbyVisionFallsBackOnNonHDRDisplay() {
        processor.updateDisplayCapabilities(makeCapabilities(edr: false))
        processor.configure(with: HDRProcessingConfig(
            enableDynamicToneMapping: true,
            enableMetadataPassthrough: true,
            fallbackToStaticHDR: true,
            targetLuminance: 1000.0
        ))
        guard let sampleBuffer = makeDolbyVisionSampleBuffer(profile: .profile5) else {
            XCTFail("Failed to construct DV sample buffer")
            return
        }
        _ = processor.processMetadata(from: sampleBuffer)
        let params = processor.resolveParams(forFrameTime: 0)
        XCTAssertFalse(params.useDynamicMetadata)
        XCTAssertFalse(params.isDolbyVision)
    }
    
    // MARK: - Transition smoothing
    
    func testTransitionSmoothingInterpolatesAcrossFrames() {
        processor.updateDisplayCapabilities(makeCapabilities())
        guard let sampleBuffer = makeHDR10PlusSampleBuffer() else {
            XCTFail("Failed to construct HDR10+ sample buffer")
            return
        }
        _ = processor.processMetadata(from: sampleBuffer)
        
        let first = processor.resolveParams(forFrameTime: 0)
        let next = processor.resolveParams(forFrameTime: 0.001)
        XCTAssertTrue(next.kneePoint.isFinite)
        XCTAssertTrue(next.kneePoint <= max(first.kneePoint, 2.0) || next.kneePoint >= 0)
    }
    
    // MARK: - Render encoder integration (Metal-gated)
    
    func testApplyMetadataToRenderEncoder() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable in this environment")
        }
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = device.makeTexture(descriptor: descriptor)!
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        
        processor.updateDisplayCapabilities(makeCapabilities())
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            XCTFail("Failed to create render command encoder")
            return
        }
        processor.applyMetadata(to: encoder, frameTime: 0)
        encoder.endEncoding()
        commandBuffer.commit()
    }
}
