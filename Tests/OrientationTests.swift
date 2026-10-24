import AppKit
import XCTest
@testable import Visor

/// `ViewOrientation.then` must give the same result as applying the two
/// changes one after the other, for every orientation and every command.
final class OrientationTests: XCTestCase {
    private static let all: [ViewOrientation] = (0..<4).flatMap { turns in
        [ViewOrientation(quarterTurns: turns, mirrored: false), ViewOrientation(quarterTurns: turns, mirrored: true)]
    }
    private static let commands: [ViewOrientation] = [.rotateLeft, .rotateRight, .flipHorizontal, .flipVertical]

    private func assertEqual(_ a: CGAffineTransform, _ b: CGAffineTransform, _ message: String, line: UInt = #line) {
        for (x, y) in [(a.a, b.a), (a.b, b.b), (a.c, b.c), (a.d, b.d), (a.tx, b.tx), (a.ty, b.ty)] {
            XCTAssertEqual(x, y, accuracy: 1e-9, message, line: line)
        }
    }

    func testComposingMatchesApplyingInSequence() {
        for start in Self.all {
            for command in Self.commands {
                assertEqual(start.then(command).transform, start.transform.concatenating(command.transform), "\(start) then \(command)")
            }
        }
    }

    func testFourTurnsAndTwoFlipsAreIdentity() {
        var o = ViewOrientation.identity
        for _ in 0..<4 { o = o.then(.rotateRight) }
        XCTAssertEqual(o, .identity)
        XCTAssertEqual(ViewOrientation.flipHorizontal.then(.flipHorizontal), .identity)
        XCTAssertEqual(ViewOrientation.flipVertical.then(.flipVertical), .identity)
        XCTAssertEqual(ViewOrientation.rotateLeft.then(.rotateRight), .identity)
    }

    /// With y pointing down, "rotate right" sends the top edge to the right.
    func testRotateRightIsClockwiseOnScreen() {
        let up = CGPoint(x: 0, y: -1) // top edge, y down
        let turned = up.applying(ViewOrientation.rotateRight.layerTransform(yDown: true))
        XCTAssertEqual(turned.x, 1, accuracy: 1e-9)
        XCTAssertEqual(turned.y, 0, accuracy: 1e-9)
        let upYUp = CGPoint(x: 0, y: 1) // top edge, y up
        let turnedYUp = upYUp.applying(ViewOrientation.rotateRight.layerTransform(yDown: false))
        XCTAssertEqual(turnedYUp.x, 1, accuracy: 1e-9)
        XCTAssertEqual(turnedYUp.y, 0, accuracy: 1e-9)
    }
}

/// Rotating and mirroring only change the layer: the bitmap stays the same object.
@MainActor
final class ReorientTests: XCTestCase {
    func testRotationKeepsTheBitmapAndSwapsTheDocument() {
        let bitmap = TestImages.solid(width: 1000, height: 750)
        let f = CanvasFixture(bitmap: bitmap)
        f.canvas.imageView.setOrientation(.rotateRight)
        f.canvas.setImagePixelSize(CGSize(width: 3000, height: 4000), refit: true)
        XCTAssertTrue(f.canvas.imageView.currentImage === bitmap)
        let frame = f.canvas.imageView.frame.size
        XCTAssertGreaterThan(frame.height, frame.width)
        XCTAssertEqual(f.canvas.imageView.orientation, .rotateRight)
        XCTAssertEqual(f.magnificationFilter, .linear, "same long side as before: still interpolated")
    }
}

final class RedrawTests: XCTestCase {
    /// 16-bit grayscale has no 16-bit gray context with alpha in Core Graphics.
    func testSixteenBitGrayscaleCanBeRedrawn() throws {
        let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 16, bytesPerRow: 0, space: gray,
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try XCTUnwrap(context.makeImage())
        let copy = try XCTUnwrap(ImageDecoder.redraw(image, width: 8, height: 6, transform: .identity))
        XCTAssertEqual(copy.bitsPerComponent, 16)
        XCTAssertEqual(copy.colorSpace?.model, .monochrome)
    }
}
