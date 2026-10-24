import AppKit
import XCTest
@testable import Visor

/// Every zoom command must take effect on the first try, starting from
/// "zoom to fit" (the state every image opens in).
@MainActor
final class ZoomTests: XCTestCase {
    func testOpensFitted() {
        let f = CanvasFixture()
        XCTAssertTrue(f.canvas.isFitting)
        XCTAssertEqual(f.canvas.magnification, f.expectedFit, accuracy: 0.0001)
    }

    func testActualPixelsWorksOnFirstPress() {
        let f = CanvasFixture()
        f.canvas.zoomToActualPixels()
        XCTAssertEqual(f.canvas.magnification, 1, accuracy: 0.0001)
        XCTAssertFalse(f.canvas.isFitting)
    }

    func testZoomInWorksOnFirstPress() {
        let f = CanvasFixture()
        f.canvas.zoom(by: 1.25)
        XCTAssertEqual(f.canvas.magnification, f.expectedFit * 1.25, accuracy: 0.0001)
    }

    func testZoomOutWorksOnFirstPress() {
        let f = CanvasFixture()
        f.canvas.zoom(by: 0.8)
        XCTAssertEqual(f.canvas.magnification, f.expectedFit * 0.8, accuracy: 0.0001)
    }

    func testDoubleClickTogglesActualPixelsAndFit() {
        let f = CanvasFixture()
        f.doubleClick()
        XCTAssertEqual(f.canvas.magnification, 1, accuracy: 0.0001, "first double-click shows actual pixels")
        f.doubleClick()
        XCTAssertEqual(f.canvas.magnification, f.expectedFit, accuracy: 0.0001, "second double-click fits again")
        XCTAssertTrue(f.canvas.isFitting)
    }

    /// A pinch is a live magnification: AppKit posts the start notification,
    /// changes the magnification (which re-tiles the view) and posts the end.
    func testPinchFromFitIsKept() {
        let f = CanvasFixture()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveMagnifyNotification, object: f.canvas)
        f.canvas.setMagnification(0.5, centeredAt: NSPoint(x: 1000, y: 750))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: f.canvas)
        XCTAssertEqual(f.canvas.magnification, 0.5, accuracy: 0.0001)
        XCTAssertFalse(f.canvas.isFitting)
    }

    func testResizingKeepsFitWhileFitting() {
        let f = CanvasFixture()
        f.window.setContentSize(NSSize(width: 400, height: 300))
        f.window.layoutIfNeeded()
        f.canvas.tile()
        XCTAssertEqual(f.canvas.magnification, f.expectedFit / 2, accuracy: 0.0001)
    }

    func testResizingKeepsZoomWhenZoomed() {
        let f = CanvasFixture()
        f.canvas.zoomToActualPixels()
        f.window.setContentSize(NSSize(width: 400, height: 300))
        f.window.layoutIfNeeded()
        f.canvas.tile()
        XCTAssertEqual(f.canvas.magnification, 1, accuracy: 0.0001)
    }
}
