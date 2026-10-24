import AppKit
import XCTest
@testable import Visor

/// Past 300 % an image pixel is drawn as a sharp square; below that it is
/// interpolated. "Image pixel" depends on the bitmap shown, which changes
/// when Visor decodes more pixels after a zoom.
@MainActor
final class PixelationTests: XCTestCase {
    func testFittedImageIsInterpolated() {
        let f = CanvasFixture()
        XCTAssertEqual(f.magnificationFilter, .linear)
    }

    func testLowResolutionBitmapAtActualPixelsIsSharp() {
        // 1000 px bitmap of a 4000 px image at 100 %: each bitmap pixel covers 4 screen pixels.
        let f = CanvasFixture()
        f.canvas.zoomToActualPixels()
        XCTAssertEqual(f.magnificationFilter, .nearest)
    }

    func testFullResolutionBitmapReplacingItIsInterpolated() {
        let f = CanvasFixture()
        f.canvas.zoomToActualPixels()
        f.canvas.display(TestImages.solid(width: 4000, height: 3000), hdr: false)
        XCTAssertEqual(f.magnificationFilter, .linear, "the refined bitmap is shown 1:1")
    }

    func testFullResolutionBitmapPastThreeHundredPercentIsSharp() {
        let f = CanvasFixture()
        f.canvas.display(TestImages.solid(width: 4000, height: 3000), hdr: false)
        f.canvas.zoomToActualPixels()
        f.canvas.zoom(by: 4)
        XCTAssertEqual(f.magnificationFilter, .nearest)
    }
}
