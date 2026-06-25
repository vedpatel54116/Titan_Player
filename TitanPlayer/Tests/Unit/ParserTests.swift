import XCTest
@testable import TitanPlayer

final class ParserTests: XCTestCase {
    func testSRTParserParsesValidSRT() throws {
        let parser = SRTParser()
        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello, world!
        
        2
        00:00:05,000 --> 00:00:08,000
        This is a test subtitle.
        """
        
        let data = srtContent.data(using: .utf8)!
        let events = try parser.parse(data: data)
        
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].startTime, 1.0)
        XCTAssertEqual(events[0].endTime, 4.0)
        XCTAssertEqual(events[0].text, AttributedString("Hello, world!"))
    }
    
    func testSRTParserHandlesEmptyInput() throws {
        let parser = SRTParser()
        let data = Data()
        
        let events = try parser.parse(data: data)
        
        XCTAssertTrue(events.isEmpty)
    }
    
    func testSRTParserHandlesMalformedInput() throws {
        let parser = SRTParser()
        let data = "invalid srt content".data(using: .utf8)!
        
        let events = try parser.parse(data: data)
        
        XCTAssertTrue(events.isEmpty)
    }
}
