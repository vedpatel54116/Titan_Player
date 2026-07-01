import XCTest
import SwiftUI
@testable import TitanPlayer

final class ColorPickerOverlayTests: XCTestCase {
    func testMapViewToSourceIdentityInFitMode() {
        // 1:1 fit with no border → view point == source pixel.
        let mapped = ColorPickerOverlay<EmptyView>.mapViewToSource(
            viewPoint: CGPoint(x: 100, y: 50),
            viewSize: CGSize(width: 800, height: 400),
            sourceSize: CGSize(width: 800, height: 400),
            fitMode: .fit,
            letterbox: .zero)
        XCTAssertEqual(mapped.x, 100, accuracy: 0.5)
        XCTAssertEqual(mapped.y, 50, accuracy: 0.5)
    }

    func testMapViewToSourceSubtractsLetterbox() {
        // 1000×500 view, 500×500 source: horizontal letterbox bars of 250 on each side.
        let mapped = ColorPickerOverlay<EmptyView>.mapViewToSource(
            viewPoint: CGPoint(x: 500, y: 250),  // dead center of view
            viewSize: CGSize(width: 1000, height: 500),
            sourceSize: CGSize(width: 500, height: 500),
            fitMode: .fit,
            letterbox: CGSize(width: 250, height: 0))
        XCTAssertEqual(mapped.x, 250, accuracy: 0.5)
        XCTAssertEqual(mapped.y, 250, accuracy: 0.5)
    }

    func testLetterboxReturnsZeroForFill() {
        let lb = ColorPickerOverlay<EmptyView>.letterbox(
            view: CGSize(width: 500, height: 500),
            source: CGSize(width: 1000, height: 500),
            fitMode: .fill)
        XCTAssertEqual(lb.width, 0)
        XCTAssertEqual(lb.height, 0)
    }

    func testLetterboxReturnsBarsForFit() {
        let lb = ColorPickerOverlay<EmptyView>.letterbox(
            view: CGSize(width: 1000, height: 500),
            source: CGSize(width: 500, height: 500),
            fitMode: .fit)
        XCTAssertEqual(lb.width, 250, accuracy: 0.5)
        XCTAssertEqual(lb.height, 0)
    }
}