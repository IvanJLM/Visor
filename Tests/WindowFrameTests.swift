import AppKit
import XCTest
@testable import Visor

/// The next window opens where the last one was, at the same size.
@MainActor
final class WindowFrameTests: XCTestCase {
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 944)
    private let external = NSRect(x: 1512, y: 0, width: 2560, height: 1415)

    func testFrameOnScreenIsKeptAsIs() {
        let frame = NSRect(x: 200, y: 100, width: 900, height: 600)
        XCTAssertEqual(WindowFrameMemory.fitted(frame, into: [laptop, external]), frame)
        let right = NSRect(x: 2000, y: 300, width: 1200, height: 800)
        XCTAssertEqual(WindowFrameMemory.fitted(right, into: [laptop, external]), right)
    }

    func testFrameHangingOffTheEdgeIsPulledBack() {
        let frame = NSRect(x: 1300, y: 600, width: 600, height: 500)
        let fitted = WindowFrameMemory.fitted(frame, into: [laptop])
        XCTAssertEqual(fitted, NSRect(x: 912, y: 444, width: 600, height: 500), "same size, whole on the screen")
    }

    func testFrameOnADisconnectedDisplayMovesToTheMainOne() {
        let frame = NSRect(x: 2500, y: 200, width: 2000, height: 1200)
        let fitted = WindowFrameMemory.fitted(frame, into: [laptop])
        XCTAssertEqual(fitted, laptop, "shrunk to the smaller display that is left")
    }

    func testNothingIsRestoredWithoutAScreenOrASize() {
        XCTAssertNil(WindowFrameMemory.fitted(NSRect(x: 0, y: 0, width: 800, height: 600), into: []))
        XCTAssertNil(WindowFrameMemory.fitted(.zero, into: [laptop]))
    }

    func testSavedFrameComesBack() throws {
        let original = WindowFrameMemory.defaults
        defer { WindowFrameMemory.defaults = original }
        XCTAssertNil(original, "the tests never touch the user's own window frame")
        let suite = "com.ivanjlm.visor.tests.frame"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        WindowFrameMemory.defaults = defaults

        XCTAssertNil(WindowFrameMemory.restored(), "first launch sizes the window to the image")
        let main = try XCTUnwrap(NSScreen.screens.first).visibleFrame
        let frame = NSRect(x: main.minX + 40, y: main.minY + 30, width: 700, height: 500)
        WindowFrameMemory.save(frame)
        XCTAssertEqual(WindowFrameMemory.restored(), frame)
    }
}
