import XCTest
import CoreMedia
@testable import TitanPlayer

final class MetadataPassthroughTests: XCTestCase {
    
    var passthroughManager: MetadataPassthroughManager!
    
    override func setUp() {
        super.setUp()
        passthroughManager = MetadataPassthroughManager()
    }
    
    override func tearDown() {
        passthroughManager = nil
        super.tearDown()
    }
    
    func testEnableDisablePassthrough() {
        passthroughManager.enablePassthrough(false)
        passthroughManager.enablePassthrough(true)
    }
    
    func testGetExternalDisplays() {
        let displays = passthroughManager.getExternalDisplays()
        XCTAssertNotNil(displays)
    }
    
    func testSupportsDolbyVisionOnUnknownDisplay() {
        let result = passthroughManager.supportsDolbyVisionOnDisplay(99999)
        XCTAssertFalse(result)
    }
    
    func testUpdateHDRMode() {
        passthroughManager.updateHDRMode(.sdr)
        
        let hdr10Metadata = HDR10Metadata(
            displayPrimaries: (
                red: SIMD2<Float>(0.708, 0.292),
                green: SIMD2<Float>(0.170, 0.797),
                blue: SIMD2<Float>(0.131, 0.046)
            ),
            whitePoint: SIMD2<Float>(0.3127, 0.3290),
            maxDisplayLuminance: 1000.0,
            minDisplayLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0
        )
        passthroughManager.updateHDRMode(.hdr10(hdr10Metadata))
    }
    
    func testProcessMetadata() {
        let metadata = MetadataPassthroughManager.PassthroughMetadata(
            hdr10Metadata: HDR10Metadata(
                displayPrimaries: (
                    red: SIMD2<Float>(0.708, 0.292),
                    green: SIMD2<Float>(0.170, 0.797),
                    blue: SIMD2<Float>(0.131, 0.046)
                ),
                whitePoint: SIMD2<Float>(0.3127, 0.3290),
                maxDisplayLuminance: 1000.0,
                minDisplayLuminance: 0.001,
                maxContentLightLevel: 1000.0,
                maxFrameAverageLightLevel: 400.0
            ),
            hdr10PlusMetadata: nil,
            dolbyVisionMetadata: nil,
            timestamp: CMTime(seconds: 0, preferredTimescale: 600)
        )
        
        passthroughManager.processMetadata(metadata, for: nil)
        passthroughManager.processMetadata(metadata, for: 12345)
    }
    
    func testPassthroughMetadataEquality() {
        let timestamp = CMTime(seconds: 1, preferredTimescale: 600)
        
        let metadata1 = MetadataPassthroughManager.PassthroughMetadata(
            hdr10Metadata: HDR10Metadata(
                displayPrimaries: (
                    red: SIMD2<Float>(0.708, 0.292),
                    green: SIMD2<Float>(0.170, 0.797),
                    blue: SIMD2<Float>(0.131, 0.046)
                ),
                whitePoint: SIMD2<Float>(0.3127, 0.3290),
                maxDisplayLuminance: 1000.0,
                minDisplayLuminance: 0.001,
                maxContentLightLevel: 1000.0,
                maxFrameAverageLightLevel: 400.0
            ),
            hdr10PlusMetadata: nil,
            dolbyVisionMetadata: nil,
            timestamp: timestamp
        )
        
        let metadata2 = MetadataPassthroughManager.PassthroughMetadata(
            hdr10Metadata: HDR10Metadata(
                displayPrimaries: (
                    red: SIMD2<Float>(0.708, 0.292),
                    green: SIMD2<Float>(0.170, 0.797),
                    blue: SIMD2<Float>(0.131, 0.046)
                ),
                whitePoint: SIMD2<Float>(0.3127, 0.3290),
                maxDisplayLuminance: 1000.0,
                minDisplayLuminance: 0.001,
                maxContentLightLevel: 1000.0,
                maxFrameAverageLightLevel: 400.0
            ),
            hdr10PlusMetadata: nil,
            dolbyVisionMetadata: nil,
            timestamp: timestamp
        )
        
        XCTAssertEqual(metadata1.timestamp, metadata2.timestamp)
    }
    
    func testExternalDisplayInfoCreation() {
        let displayInfo = MetadataPassthroughManager.ExternalDisplayInfo(
            displayID: 12345,
            supportsHDR: true,
            supportsDolbyVision: false,
            maxLuminance: 1600.0,
            colorGamut: .bt2020,
            lastMetadataTimestamp: Date()
        )
        
        XCTAssertEqual(displayInfo.displayID, 12345)
        XCTAssertTrue(displayInfo.supportsHDR)
        XCTAssertFalse(displayInfo.supportsDolbyVision)
        XCTAssertEqual(displayInfo.maxLuminance, 1600.0)
        XCTAssertEqual(displayInfo.colorGamut, .bt2020)
    }
}
