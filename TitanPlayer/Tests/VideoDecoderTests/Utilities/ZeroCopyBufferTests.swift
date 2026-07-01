import XCTest
import CoreMedia
import CoreVideo
@testable import TitanPlayer

final class ZeroCopyBufferTests: XCTestCase {
    
    var bufferManager: ZeroCopyBufferManager!
    
    override func setUp() {
        super.setUp()
        bufferManager = ZeroCopyBufferManager()
    }
    
    override func tearDown() {
        bufferManager = nil
        super.tearDown()
    }
    
    // MARK: - Annex-B → AVCC Conversion
    
    func testAnnexBToAVCCConvertsStartCodesToLengthPrefixes() {
        let annexB: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02,
            0x00, 0x00, 0x00, 0x01,
            0x68, 0xCE, 0x38, 0x80
        ]
        
        let avcc = ZeroCopyBufferManager.annexBToAVCC(Data(annexB))
        let avccBytes = [UInt8](avcc)
        
        XCTAssertEqual(avccBytes[0], 0x00)
        XCTAssertEqual(avccBytes[1], 0x00)
        XCTAssertEqual(avccBytes[2], 0x00)
        XCTAssertEqual(avccBytes[3], 0x06, "First NALU length should be 6")
        XCTAssertEqual(avccBytes[4], 0x67)
        
        let secondStart = 10
        XCTAssertEqual(avccBytes[secondStart], 0x00)
        XCTAssertEqual(avccBytes[secondStart + 1], 0x00)
        XCTAssertEqual(avccBytes[secondStart + 2], 0x00)
        XCTAssertEqual(avccBytes[secondStart + 3], 0x04, "Second NALU length should be 4")
        XCTAssertEqual(avccBytes[secondStart + 4], 0x68)
    }
    
    func testAnnexBToAVCCHandles3ByteStartCodes() {
        let annexB: [UInt8] = [
            0x00, 0x00, 0x01,
            0x67, 0x42, 0xC0,
        ]
        
        let avcc = ZeroCopyBufferManager.annexBToAVCC(Data(annexB))
        let avccBytes = [UInt8](avcc)
        
        XCTAssertEqual(avccBytes[0], 0x00)
        XCTAssertEqual(avccBytes[1], 0x00)
        XCTAssertEqual(avccBytes[2], 0x00)
        XCTAssertEqual(avccBytes[3], 0x03, "NALU length should be 3")
    }
    
    func testAnnexBToAVCCEmptyDataReturnsEmpty() {
        let result = ZeroCopyBufferManager.annexBToAVCC(Data())
        XCTAssertTrue(result.isEmpty)
    }
    
    func testAnnexBToAVCCNoStartCodeReturnsLengthPrefixedData() {
        let raw: [UInt8] = [0x67, 0x42, 0xC0]
        let result = ZeroCopyBufferManager.annexBToAVCC(Data(raw))
        XCTAssertEqual(result.count, 4 + 3)
        XCTAssertEqual([UInt8](result)[3], 0x03)
    }
    
    // MARK: - Pixel Buffer Pool
    
    func testCreatePixelBufferPool() {
        let pool = bufferManager.createPixelBufferPool(
            width: 320,
            height: 240,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertNotNil(pool)
        
        let pixelBuffer = bufferManager.getPixelBuffer(from: pool)
        XCTAssertNotNil(pixelBuffer)
        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer!), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer!), 240)
    }
    
    // MARK: - Buffer Reuse
    
    func testBufferReuseQueue() {
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 320, height: 240,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDesc = formatDescription else {
            XCTFail("Failed to create format description")
            return
        }
        
        let packet = MediaPacket(
            streamIndex: 0,
            data: Data(repeating: 0, count: 100),
            timestamp: CMTime(seconds: 0, preferredTimescale: 600),
            duration: CMTime(seconds: 0.033, preferredTimescale: 600),
            isKeyFrame: true
        )
        
        let sampleBuffer = try? bufferManager.createSampleBuffer(
            from: packet,
            formatDescription: formatDesc
        )
        XCTAssertNotNil(sampleBuffer)
        
        if let buffer = sampleBuffer {
            bufferManager.enqueueBuffer(buffer)
            let dequeued = bufferManager.dequeueBuffer()
            XCTAssertNotNil(dequeued)
        }
    }
}
