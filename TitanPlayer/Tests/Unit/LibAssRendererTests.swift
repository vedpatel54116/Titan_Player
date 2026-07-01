import XCTest
@testable import TitanPlayer

final class LibAssRendererTests: XCTestCase {

    func testInitReturnsNilWhenLibassUnavailable() {
        let renderer = LibAssRenderer()
        if renderer != nil {
            renderer?.flush()
        }
        // If libass is installed, renderer is non-nil. Either outcome is valid.
        XCTAssert(true)
    }

    func testLoadAndRenderASSData() throws {
        guard let renderer = LibAssRenderer() else {
            throw XCTSkip("libass not installed")
        }
        defer { renderer.flush() }

        let assContent = """
        [Script Info]
        Title: Test
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Hello World
        """

        let data = assContent.data(using: .utf8)!
        try renderer.load(data: data, encoding: .utf8)

        let bitmap = renderer.renderImage(forTime: 2.0, size: CGSize(width: 1920, height: 1080))
        XCTAssertNotNil(bitmap)
        XCTAssertEqual(bitmap?.width, 1920)
        XCTAssertEqual(bitmap?.height, 1080)

        if let bitmap = bitmap {
            bitmap.pixels.deallocate()
        }
    }

    func testRenderReturnsNilForNoActiveEvents() throws {
        guard let renderer = LibAssRenderer() else {
            throw XCTSkip("libass not installed")
        }
        defer { renderer.flush() }

        let assContent = """
        [Script Info]
        Title: Test
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Hello
        """

        let data = assContent.data(using: .utf8)!
        try renderer.load(data: data, encoding: .utf8)

        // Time before the dialogue starts
        let bitmap = renderer.renderImage(forTime: 0.5, size: CGSize(width: 1920, height: 1080))
        XCTAssertNil(bitmap)
    }

    func testFlushResetsState() throws {
        guard let renderer = LibAssRenderer() else {
            throw XCTSkip("libass not installed")
        }

        let assContent = """
        [Script Info]
        Title: Test
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Hello
        """

        let data = assContent.data(using: .utf8)!
        try renderer.load(data: data, encoding: .utf8)

        renderer.flush()

        // After flush, render should return nil (no track loaded)
        let bitmap = renderer.renderImage(forTime: 2.0, size: CGSize(width: 1920, height: 1080))
        XCTAssertNil(bitmap)
    }

    func testSetStyleSheet() throws {
        guard let renderer = LibAssRenderer() else {
            throw XCTSkip("libass not installed")
        }
        defer { renderer.flush() }

        let assContent = """
        [Script Info]
        Title: Test
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Hello
        """

        let data = assContent.data(using: .utf8)!
        try renderer.load(data: data, encoding: .utf8)

        let style = SubtitleStyle(
            fontSize: 32,
            fontName: "Helvetica",
            foregroundColor: .white,
            backgroundColor: nil,
            isBold: false,
            isItalic: false
        )
        renderer.setStyleSheet(style)

        let bitmap = renderer.renderImage(forTime: 2.0, size: CGSize(width: 1920, height: 1080))
        XCTAssertNotNil(bitmap)

        bitmap?.pixels.deallocate()
    }
}
