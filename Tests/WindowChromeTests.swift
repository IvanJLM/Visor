import AppKit
import XCTest
@testable import Visor

/// The title bar lives inside the image and only shows while the mouse moves.
@MainActor
final class WindowChromeTests: XCTestCase {
    func testImageFillsTheWholeWindow() throws {
        let controller = ImageWindowController(cascadeFrom: nil)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), "the image goes under the title bar")
        XCTAssertTrue(window.titlebarAppearsTransparent)
        let canvas = try XCTUnwrap(window.contentView?.subviews.first as? ImageCanvas)
        XCTAssertFalse(canvas.automaticallyAdjustsContentInsets)
        XCTAssertEqual(canvas.contentInsets.top, 0, "no band is kept free for the title bar")
        XCTAssertEqual(canvas.frame, window.contentView?.bounds, "the canvas covers the window")
    }

    func testTitleBarShowsOnMoveAndHidesWhenIdle() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        let chrome = WindowChrome(window: window, container: window.contentView!)
        let titlebar = window.standardWindowButton(.closeButton)?.superview

        chrome.show()
        XCTAssertTrue(chrome.isShown)
        let timer = chrome.hideTimer
        XCTAssertNotNil(timer, "the countdown starts when the mouse moves")
        XCTAssertGreaterThan(timer?.tolerance ?? 0, 0, "the hide timer may be grouped with other wake-ups")

        chrome.hide()
        XCTAssertFalse(chrome.isShown)
        XCTAssertNil(chrome.hideTimer, "nothing runs once the title bar is hidden")

        chrome.suspend()
        XCTAssertTrue(chrome.isShown, "full screen: macOS shows the title bar itself")
        XCTAssertEqual(titlebar?.alphaValue ?? 1, 1)
        XCTAssertNil(chrome.hideTimer)
        chrome.resume()
        XCTAssertNotNil(chrome.hideTimer)

        chrome.stop()
        XCTAssertNil(chrome.hideTimer, "no timer outlives the window")
    }

    func testMacOSNeverQuitsVisorBehindAHiddenWindow() {
        // With automatic termination, macOS may quit an app whose only window
        // is minimized or on another space.
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSSupportsAutomaticTermination"))
    }
}
