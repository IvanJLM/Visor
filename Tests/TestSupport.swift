import AppKit
@testable import Visor

/// Small helpers shared by the tests.
enum TestImages {
    /// A solid 8-bit bitmap of the given size.
    static func solid(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

/// A window with a canvas the size of an 800 × 600 window, showing a
/// 4000 × 3000 image fitted (magnification 0.2 on a 1x screen).
@MainActor
final class CanvasFixture {
    let window: NSWindow
    let canvas: ImageCanvas

    init(imagePixels: CGSize = CGSize(width: 4000, height: 3000), bitmap: CGImage? = nil) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = canvas
        window.layoutIfNeeded()
        canvas.setImagePixelSize(imagePixels, refit: true)
        canvas.display(bitmap ?? TestImages.solid(width: 1000, height: 750), hdr: false)
    }

    var scale: CGFloat { window.backingScaleFactor }

    /// Magnification at which the whole image fits the 800 × 600 canvas.
    var expectedFit: CGFloat { min(1, 800 / (4000 / scale), 600 / (3000 / scale)) }

    func doubleClick() {
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 400, y: 300), modifierFlags: [],
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 2, pressure: 1)!
        canvas.mouseDown(with: event)
    }
}

extension CanvasFixture {
    /// The filter Core Animation uses to enlarge the bitmap.
    var magnificationFilter: CALayerContentsFilter? { canvas.imageView.layer?.magnificationFilter }
}
