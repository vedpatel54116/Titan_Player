import XCTest
import CoreMedia
import VideoToolbox
@testable import TitanPlayer

final class ParameterSetParserTests: XCTestCase {
    
    // MARK: - H.264 avcC Parsing
    
    func testParseH264AvcCReturnsFormatDescription() throws {
        let avcC: [UInt8] = [
            0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1,
            0x00, 0x09, 0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80, 0xF6, 0x80,
            0x01, 0x00, 0x04, 0x68, 0xCE, 0x38, 0x80
        ]
        
        let formatDesc = ParameterSetParser.parseH264(extradata: Data(avcC))
        XCTAssertNotNil(formatDesc, "Should create CMVideoFormatDescription from valid avcC")
    }
    
    func testParseH264InvalidAvcCReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02])
        let result = ParameterSetParser.parseH264(extradata: garbage)
        XCTAssertNil(result, "Should return nil for invalid avcC data")
    }
    
    func testParseH264EmptyDataReturnsNil() {
        let result = ParameterSetParser.parseH264(extradata: Data())
        XCTAssertNil(result)
    }
    
    // MARK: - HEVC hvcC Parsing
    
    func testParseHEVCInvalidDataReturnsNil() {
        let garbage = Data([0xFF, 0xFF])
        let result = ParameterSetParser.parseHEVC(extradata: garbage)
        XCTAssertNil(result)
    }
    
    func testParseHEVCEmptyDataReturnsNil() {
        let result = ParameterSetParser.parseHEVC(extradata: Data())
        XCTAssertNil(result)
    }
    
    // MARK: - Annex-B Parsing
    
    func testParseAnnexBH264ExtractsSPSAndPPS() throws {
        let annexB: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80, 0xF6, 0x80,
            0x00, 0x00, 0x00, 0x01,
            0x68, 0xCE, 0x38, 0x80
        ]
        
        let formatDesc = ParameterSetParser.parseAnnexB(extradata: Data(annexB), codec: .h264)
        XCTAssertNotNil(formatDesc, "Should create CMVideoFormatDescription from Annex-B H.264")
    }
    
    func testParseAnnexBHEVCReturnsNilForNoVPS() {
        let annexB: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0xAC, 0x09,
            0x00, 0x00, 0x00, 0x01,
            0x44, 0x01, 0xC1, 0x73, 0xD1, 0x89
        ]
        
        let result = ParameterSetParser.parseAnnexB(extradata: Data(annexB), codec: .hevc)
        XCTAssertNil(result, "HEVC requires VPS — should return nil without it")
    }
    
    func testParseAnnexBInvalidDataReturnsNil() {
        let result = ParameterSetParser.parseAnnexB(extradata: Data([0x00, 0x01]), codec: .h264)
        XCTAssertNil(result)
    }
    
    // MARK: - Main Entry Point
    
    func testParseFormatDescriptionDispatchesByCodec() {
        let avcC: [UInt8] = [
            0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1,
            0x00, 0x09, 0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80, 0xF6, 0x80,
            0x01, 0x00, 0x04, 0x68, 0xCE, 0x38, 0x80
        ]
        let h264Result = ParameterSetParser.parseFormatDescription(
            extradata: Data(avcC),
            codec: .h264,
            width: 320,
            height: 240
        )
        XCTAssertNotNil(h264Result)
    }
    
    func testParseFormatDescriptionNilExtradataReturnsBasicForH264() {
        let result = ParameterSetParser.parseFormatDescription(
            extradata: nil,
            codec: .h264,
            width: 320,
            height: 240
        )
        XCTAssertNotNil(result, "Should create basic format description even without extradata")
    }
    
    func testParseFormatDescriptionVP9ReturnsBasicFormatDesc() {
        let result = ParameterSetParser.parseFormatDescription(
            extradata: nil,
            codec: .vp9,
            width: 320,
            height: 240
        )
        if HardwareCapabilities.isCodecSupported(.vp9) {
            XCTAssertNotNil(result)
        }
    }
    
    // MARK: - Annex-B Splitting
    
    func testSplitAnnexBNALUsFindsAllNALUs() {
        let annexB: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xC0,
            0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x38, 0x80
        ]
        
        let nalus = ParameterSetParser.splitAnnexBNALUs(Data(annexB))
        XCTAssertEqual(nalus.count, 2)
        XCTAssertEqual(nalus[0][0] & 0x1F, 7, "First NALU should be SPS (type 7)")
        XCTAssertEqual(nalus[1][0] & 0x1F, 8, "Second NALU should be PPS (type 8)")
    }
    
    func testSplitAnnexBWith3ByteStartCodes() {
        let annexB: [UInt8] = [
            0x00, 0x00, 0x01, 0x67, 0x42,
            0x00, 0x00, 0x01, 0x68, 0xCE
        ]
        
        let nalus = ParameterSetParser.splitAnnexBNALUs(Data(annexB))
        XCTAssertEqual(nalus.count, 2)
    }
}
