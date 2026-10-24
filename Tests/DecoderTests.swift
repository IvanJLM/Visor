import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Visor

/// Full-size decoding skips ImageIO's thumbnail path and turns the pixels
/// upright itself: it must give exactly what the thumbnail path gave.
final class DecoderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("VisorDecoderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A 5 × 3 image with a different color in every pixel, saved as a
    /// lossless TIFF with the given EXIF orientation.
    private func writeMarked(orientation: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 5, height: 3, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for y in 0..<3 { for x in 0..<5 {
            context.setFillColor(CGColor(red: CGFloat(x) / 4, green: CGFloat(y) / 2, blue: CGFloat((x + y) % 3) / 2, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let url = folder.appendingPathComponent("o\(orientation).tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                   [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    func testFullSizeMatchesImageIOForEveryOrientation() throws {
        for orientation in 1...8 {
            let url = try writeMarked(orientation: orientation)
            let source = try XCTUnwrap(ImageDecoder.source(for: url))
            let reference = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 5,
            ] as CFDictionary))
            let info = try XCTUnwrap(ImageDecoder.info(for: url, source: source, checkGainMap: false))
            let decoded = try XCTUnwrap(ImageDecoder.decode(source: source, info: info, maxPixel: .max, wantsHDR: false,
                                                            screenSpace: sRGB))
            XCTAssertTrue(decoded.isFullResolution)
            XCTAssertEqual(decoded.image.width, info.pixelWidth, "orientation \(orientation)")
            XCTAssertEqual(decoded.image.width, reference.width, "orientation \(orientation)")
            XCTAssertEqual(pixels(decoded.image), pixels(reference), "orientation \(orientation)")
        }
    }

    func testSmallerTargetsStillUseTheScaledPath() throws {
        let url = try writeMarked(orientation: 6)
        let source = try XCTUnwrap(ImageDecoder.source(for: url))
        let info = try XCTUnwrap(ImageDecoder.info(for: url, source: source, checkGainMap: false))
        let decoded = try XCTUnwrap(ImageDecoder.decode(source: source, info: info, maxPixel: 3, wantsHDR: false, screenSpace: sRGB))
        XCTAssertEqual(max(decoded.image.width, decoded.image.height), 3)
        XCTAssertGreaterThan(decoded.image.height, decoded.image.width, "orientation 6 is portrait once upright")
    }

    /// Asking again for the neighbour that is already prefetched (a focus
    /// change, a zoom refinement) must not decode it again.
    func testPrefetchingTheSameNeighbourTwiceDecodesOnce() throws {
        let url = try writeMarked(orientation: 1)
        let loader = ImageLoader()
        let request = ImageLoader.Request(url: url, viewportPixels: CGSize(width: 100, height: 100), wantsHDR: false, screenSpace: sRGB)
        let before = ImageDecoder.decodeCount.value
        loader.prefetch(request)
        loader.prefetch(request)
        loader.prefetch(request)
        loader.waitUntilIdle()
        XCTAssertEqual(ImageDecoder.decodeCount.value - before, 1)
        // Showing it then uses the prefetched bitmap: no decode either.
        let done = expectation(description: "load")
        var shown: ImageLoader.Result?
        loader.load(request) { result in shown = result; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(ImageDecoder.decodeCount.value - before, 1)
        guard case .image = shown else { return XCTFail("expected an image") }
    }
}
