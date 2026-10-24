import CoreGraphics
import XCTest
@testable import Visor

/// `ViewOrientation.then` must give the same result as applying the two
/// changes one after the other, for every orientation and every command.
final class OrientationTests: XCTestCase {
    /// A 3 × 2 bitmap with a different value in every pixel.
    private func marked() -> CGImage {
        let context = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        for y in 0..<2 { for x in 0..<3 {
            context.setFillColor(CGColor(red: CGFloat(x) / 2, green: CGFloat(y), blue: 0.5, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return context.makeImage()!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    private static let all: [ViewOrientation] = (0..<4).flatMap { turns in
        [ViewOrientation(quarterTurns: turns, mirrored: false), ViewOrientation(quarterTurns: turns, mirrored: true)]
    }
    private static let commands: [ViewOrientation] = [.rotateLeft, .rotateRight, .flipHorizontal, .flipVertical]

    func testComposingMatchesApplyingInSequence() throws {
        let source = marked()
        for start in Self.all {
            for command in Self.commands {
                let stepwise = try XCTUnwrap(command.apply(to: try XCTUnwrap(start.apply(to: source))))
                let composed = try XCTUnwrap(start.then(command).apply(to: source))
                XCTAssertEqual(composed.width, stepwise.width)
                XCTAssertEqual(pixels(composed), pixels(stepwise), "\(start) then \(command)")
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
}
