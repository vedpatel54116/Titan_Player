import XCTest
import CoreMedia
@testable import TitanPlayer

final class DolbyVisionParserTests: XCTestCase {
    
    var parser: DolbyVisionParser!
    
    override func setUp() {
        super.setUp()
        parser = DolbyVisionParser()
    }
    
    override func tearDown() {
        parser = nil
        super.tearDown()
    }
    
    func testDolbyVisionProfileProperties() {
        XCTAssertEqual(DolbyVisionProfile.profile4.supportsDualLayer, true)
        XCTAssertEqual(DolbyVisionProfile.profile5.supportsDualLayer, false)
        XCTAssertEqual(DolbyVisionProfile.profile7.supportsDualLayer, true)
        XCTAssertEqual(DolbyVisionProfile.profile8.supportsDualLayer, false)
        
        XCTAssertEqual(DolbyVisionProfile.profile4.colorSpace, "BT.2020")
        XCTAssertEqual(DolbyVisionProfile.profile8.colorSpace, "IPT-PQ")
    }
    
    func testParseInsufficientRPUDataReturnsNil() {
        let data = Data([0x00, 0x01])
        let result = parser.parseRPUData(data, profile: .profile5)
        XCTAssertNil(result)
    }
    
    func testSelectTrimPass() {
        let trimPass1 = DolbyVisionTrimPass(
            trimInfo: DolbyVisionTrimInfo(percentile: 50, targetMaxLuminance: 600, targetMinLuminance: 1),
            targetDisplayIndex: 0
        )
        
        let trimPass2 = DolbyVisionTrimPass(
            trimInfo: DolbyVisionTrimInfo(percentile: 90, targetMaxLuminance: 1000, targetMinLuminance: 1),
            targetDisplayIndex: 1
        )
        
        let rpuMetadata = DolbyVisionRPUMetadata(
            sceneRefreshFlag: false,
            targetDisplayMaxLuminance: 1000,
            targetDisplayMinLuminance: 1,
            trimPasses: [trimPass1, trimPass2],
            activeAreaOffsets: nil
        )
        
        let metadata = DolbyVisionMetadata(
            profile: .profile5,
            blVideoSignalInfo: DolbyVisionVideoSignalInfo(
                colorSpace: .bt2020,
                transferCharacteristic: .pq,
                colorPrimaries: .bt2020
            ),
            elVideoSignalInfo: nil,
            rpuMetadata: rpuMetadata
        )
        
        let capabilities = DisplayCapabilities(
            supportsHDR: true,
            supportsEDR: true,
            maxEDRLuminance: 1000.0,
            colorGamut: .bt2020
        )
        
        let selectedPass = parser.selectTrimPass(for: metadata, displayCapabilities: capabilities)
        
        XCTAssertNotNil(selectedPass)
        XCTAssertEqual(selectedPass?.trimInfo.targetMaxLuminance, 1000)
    }
    
    func testGenerateToneMappingParams() {
        let metadata = DolbyVisionMetadata(
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
        )
        
        let capabilities = DisplayCapabilities(
            supportsHDR: true,
            supportsEDR: true,
            maxEDRLuminance: 1600.0,
            colorGamut: .bt2020
        )
        
        let params = parser.generateToneMappingParams(for: metadata, trimPass: nil, displayCapabilities: capabilities)
        
        XCTAssertEqual(params.luminanceScale, 1.6)
        XCTAssertGreaterThan(params.saturationScale, 0)
    }
    
    func testDolbyVisionColorSpaceValues() {
        XCTAssertEqual(DolbyVisionColorSpace.bt709.rawValue, 1)
        XCTAssertEqual(DolbyVisionColorSpace.bt2020.rawValue, 2)
    }
    
    func testDolbyVisionTransferCharacteristicValues() {
        XCTAssertEqual(DolbyVisionTransferCharacteristic.sdr.rawValue, 1)
        XCTAssertEqual(DolbyVisionTransferCharacteristic.pq.rawValue, 2)
        XCTAssertEqual(DolbyVisionTransferCharacteristic.hlg.rawValue, 3)
    }
    
    func testDolbyVisionColorPrimariesValues() {
        XCTAssertEqual(DolbyVisionColorPrimaries.bt709.rawValue, 1)
        XCTAssertEqual(DolbyVisionColorPrimaries.bt2020.rawValue, 2)
    }
    
    func testDolbyVisionMetadataEquality() {
        let rpuMetadata = DolbyVisionRPUMetadata(
            sceneRefreshFlag: false,
            targetDisplayMaxLuminance: 1000,
            targetDisplayMinLuminance: 1,
            trimPasses: [],
            activeAreaOffsets: nil
        )
        
        let metadata1 = DolbyVisionMetadata(
            profile: .profile5,
            blVideoSignalInfo: DolbyVisionVideoSignalInfo(
                colorSpace: .bt2020,
                transferCharacteristic: .pq,
                colorPrimaries: .bt2020
            ),
            elVideoSignalInfo: nil,
            rpuMetadata: rpuMetadata
        )
        
        let metadata2 = DolbyVisionMetadata(
            profile: .profile5,
            blVideoSignalInfo: DolbyVisionVideoSignalInfo(
                colorSpace: .bt2020,
                transferCharacteristic: .pq,
                colorPrimaries: .bt2020
            ),
            elVideoSignalInfo: nil,
            rpuMetadata: rpuMetadata
        )
        
        XCTAssertEqual(metadata1, metadata2)
    }
    
    func testDolbyVisionToneMappingParamsCreation() {
        let params = DolbyVisionToneMappingParams(
            luminanceScale: 1.5,
            minLuminanceScale: 0.5,
            saturationScale: 0.95,
            contrastAdjustment: 0.1,
            brightnessAdjustment: 0.05
        )
        
        XCTAssertEqual(params.luminanceScale, 1.5)
        XCTAssertEqual(params.minLuminanceScale, 0.5)
        XCTAssertEqual(params.saturationScale, 0.95)
        XCTAssertEqual(params.contrastAdjustment, 0.1)
        XCTAssertEqual(params.brightnessAdjustment, 0.05)
    }
}
