import XCTest
import CoreMedia
@testable import TitanPlayer

final class HDR10PlusParserTests: XCTestCase {
    
    var parser: HDR10PlusParser!
    
    override func setUp() {
        super.setUp()
        parser = HDR10PlusParser()
    }
    
    override func tearDown() {
        parser = nil
        super.tearDown()
    }
    
    func testParseInsufficientDataReturnsNil() {
        let messages = [
            SEIMessage(
                type: .hdr10Plus,
                payload: Data([0x00, 0x01, 0x02]),
                timestamp: CMTime(seconds: 0, preferredTimescale: 600)
            )
        ]
        let result = parser.parseSEIMessages(messages)
        XCTAssertTrue(result.isEmpty)
    }
    
    func testGenerateDynamicToneMappingParams() {
        let metadata = HDR10PlusMetadata(
            curveExponent: 20,
            kneePointX: 2048,
            kneePointY: 1024,
            numBezierCurveAnchors: 2,
            bezierCurveAnchors: [32, 64],
            colorSaturationMap: [128, 128, 128]
        )
        
        let capabilities = DisplayCapabilities(
            supportsHDR: true,
            supportsEDR: true,
            maxEDRLuminance: 1600.0,
            colorGamut: .bt2020
        )
        
        let params = parser.generateDynamicToneMappingParams(for: metadata, displayCapabilities: capabilities)
        
        XCTAssertGreaterThan(params.kneePoint, 0)
        XCTAssertGreaterThan(params.compressionRatio, 0)
        XCTAssertGreaterThan(params.colorSaturationScale, 0)
    }
    
    func testParseSEIMessages() {
        let messages = [
            SEIMessage(
                type: .hdr10Plus,
                payload: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A]),
                timestamp: CMTime(seconds: 0, preferredTimescale: 600)
            )
        ]
        
        let metadataList = parser.parseSEIMessages(messages)
        
        XCTAssertEqual(metadataList.count, 1)
    }
    
    func testParseUnknownSEIMessages() {
        let messages = [
            SEIMessage(
                type: .unknown,
                payload: nil,
                timestamp: CMTime(seconds: 0, preferredTimescale: 600)
            )
        ]
        
        let metadataList = parser.parseSEIMessages(messages)
        
        XCTAssertTrue(metadataList.isEmpty)
    }
    
    func testHDR10PlusMetadataEquality() {
        let metadata1 = HDR10PlusMetadata(
            curveExponent: 20,
            kneePointX: 2048,
            kneePointY: 1024,
            numBezierCurveAnchors: 2,
            bezierCurveAnchors: [32, 64],
            colorSaturationMap: [128]
        )
        
        let metadata2 = HDR10PlusMetadata(
            curveExponent: 20,
            kneePointX: 2048,
            kneePointY: 1024,
            numBezierCurveAnchors: 2,
            bezierCurveAnchors: [32, 64],
            colorSaturationMap: [128]
        )
        
        XCTAssertEqual(metadata1, metadata2)
    }
    
    func testDynamicToneMappingParamsCreation() {
        let params = DynamicToneMappingParams(
            kneePoint: 0.5,
            compressionRatio: 0.8,
            colorSaturationScale: 1.0,
            brightnessAdjustment: 0.1
        )
        
        XCTAssertEqual(params.kneePoint, 0.5)
        XCTAssertEqual(params.compressionRatio, 0.8)
        XCTAssertEqual(params.colorSaturationScale, 1.0)
        XCTAssertEqual(params.brightnessAdjustment, 0.1)
    }
    
    func testSEIMessageCreation() {
        let timestamp = CMTime(seconds: 1, preferredTimescale: 600)
        let message = SEIMessage(
            type: .hdr10Plus,
            payload: Data([0x01, 0x02]),
            timestamp: timestamp
        )
        
        XCTAssertEqual(message.type, .hdr10Plus)
        XCTAssertEqual(message.timestamp, timestamp)
        XCTAssertEqual(message.payload?.count, 2)
    }
}
