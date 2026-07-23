import XCTest
import CoreMedia
import CoreVideo
@testable import TitanPlayer

/// Exercises `FakeVideoDecoder` — the FFmpeg-free decoder that lets the test
/// suite run on CI machines without the locally built FFmpeg xcframeworks.
final class FakeVideoDecoderTests: XCTestCase {

    private func makeTrack(width: Int, height: Int) -> VideoTrackInfo {
        VideoTrackInfo(
            codec: "avc1",
            width: width,
            height: height,
            frameRate: 0,
            isHDR: false,
            extradata: nil
        )
    }

    private func makePacket() -> MediaPacket {
        MediaPacket(
            streamIndex: 0,
            data: Data(),
            timestamp: .zero,
            duration: .zero,
            isKeyFrame: true
        )
    }

    func testProducesSolidColorPixelBuffer() throws {
        let decoder = FakeVideoDecoder(width: 64, height: 32, color: (10, 20, 30))
        try await decoder.configure(for: makeTrack(width: 64, height: 32))

        let output = try await decoder.decode(makePacket())
        guard case .pixelBuffer(let buffer) = output else {
            XCTFail("FakeVideoDecoder should emit a pixel buffer")
            return
        }

        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 32)
        XCTAssertEqual(decoder.negotiatedPixelFormat, kCVPixelFormatType_32BGRA)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            XCTFail("Pixel buffer base address unavailable")
            return
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let offset = 10 * bytesPerRow + 5 * 4
        XCTAssertEqual(ptr[offset + 0], 30, "blue channel")
        XCTAssertEqual(ptr[offset + 1], 20, "green channel")
        XCTAssertEqual(ptr[offset + 2], 10, "red channel")
        XCTAssertEqual(ptr[offset + 3], 255, "alpha channel")
    }

    func testDecodeBeforeConfigureThrows() async {
        let decoder = FakeVideoDecoder()
        let packet = makePacket()
        do {
            _ = try await decoder.decode(packet)
            XCTFail("Decode before configure should throw")
        } catch {
            XCTAssertTrue(error is DecoderError, "Expected DecoderError")
        }
    }

    func testStaticBufferFactoryFillsColor() throws {
        let buffer = try FakeVideoDecoder.makeSolidColorBuffer(
            width: 4,
            height: 4,
            color: (1, 2, 3)
        )
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 4)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 4)
    }
}
