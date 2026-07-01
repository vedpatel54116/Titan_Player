import XCTest
@testable import TitanPlayer

final class MPDParserTests: XCTestCase {
    private let baseMPD = """
    <?xml version="1.0" encoding="UTF-8"?>
    <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"
         type="static"
         mediaPresentationDuration="PT30M0S"
         minBufferTime="PT2S">
      <Period>
        <AdaptationSet id="video" mimeType="video/mp4" segmentAlignment="true">
          <Representation id="v1" bandwidth="1000000" width="640" height="360" codecs="avc1.4d401e"/>
          <Representation id="v2" bandwidth="2500000" width="1280" height="720" codecs="avc1.4d401f"/>
          <Representation id="v3" bandwidth="5000000" width="1920" height="1080" codecs="avc1.640028"/>
        </AdaptationSet>
        <AdaptationSet id="audio" mimeType="audio/mp4" lang="en">
          <Representation id="a1" bandwidth="128000" codecs="mp4a.40.2"/>
        </AdaptationSet>
      </Period>
    </MPD>
    """

    func testParseStaticMPD() throws {
        let data = baseMPD.data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        let manifest = try MPDParser.parse(data: data, baseURL: url)

        XCTAssertEqual(manifest.type, .static)
        XCTAssertEqual(manifest.mediaPresentationDuration, 1800.0)
        XCTAssertEqual(manifest.minBufferTime, 2.0)
    }

    func testParseVideoAdaptations() throws {
        let data = baseMPD.data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        let manifest = try MPDParser.parse(data: data, baseURL: url)

        XCTAssertEqual(manifest.videoAdaptations.count, 1)
        let video = manifest.videoAdaptations[0]
        XCTAssertEqual(video.mimeType, "video/mp4")
        XCTAssertEqual(video.representations.count, 3)
    }

    func testParseVideoRepresentationsSorted() throws {
        let data = baseMPD.data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        let manifest = try MPDParser.parse(data: data, baseURL: url)

        let quals = manifest.lowestVideoQuality
        XCTAssertNotNil(quals)
        XCTAssertEqual(quals?.id, "v1")
        XCTAssertEqual(quals?.bandwidth, 1_000_000)
        XCTAssertEqual(quals?.width, 640)
        XCTAssertEqual(quals?.height, 360)
    }

    func testParseAudioAdaptations() throws {
        let data = baseMPD.data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        let manifest = try MPDParser.parse(data: data, baseURL: url)

        XCTAssertEqual(manifest.audioAdaptations.count, 1)
        let audio = manifest.audioAdaptations[0]
        XCTAssertEqual(audio.lang, "en")
        XCTAssertEqual(audio.representations.first?.bandwidth, 128_000)
    }

    func testParseInvalidXMLThrows() {
        let data = "not xml".data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        XCTAssertThrowsError(try MPDParser.parse(data: data, baseURL: url))
    }

    func testAllVideoQualitiesFlattened() throws {
        let data = baseMPD.data(using: .utf8)!
        let url = URL(string: "https://example.com/test.mpd")!
        let manifest = try MPDParser.parse(data: data, baseURL: url)

        XCTAssertEqual(manifest.allVideoQualities.count, 3)
    }
}
