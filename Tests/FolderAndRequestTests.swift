import CoreGraphics
import XCTest
@testable import Visor

final class FolderScannerTests: XCTestCase {
    func testListsImagesInFinderOrderAndSkipsTheRest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VisorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["img10.png", "img2.png", "IMG1.jpg", "notes.txt", ".hidden.png", "photo.heic"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data([0]))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("folder.png"), withIntermediateDirectories: true)
        let names = FolderScanner.images(in: folder).map(\.lastPathComponent)
        XCTAssertEqual(names, ["IMG1.jpg", "img2.png", "img10.png", "photo.heic"])
    }
}

final class RequestTests: XCTestCase {
    private func info(_ w: Int, _ h: Int) -> ImageInfo {
        ImageInfo(url: URL(fileURLWithPath: "/x.jpg"), pixelWidth: w, pixelHeight: h, isAnimated: false, hasGainMap: false)
    }

    func testFitsTheViewportAndNeverEnlarges() {
        let request = ImageLoader.Request(url: URL(fileURLWithPath: "/x.jpg"), viewportPixels: CGSize(width: 2000, height: 1000),
                                          wantsHDR: false, screenSpace: nil)
        XCTAssertEqual(request.targetLongSide(for: info(4000, 3000)), 1334) // height limits: 3000 → 1000
        XCTAssertEqual(request.targetLongSide(for: info(8000, 2000)), 8000 / 4) // width limits: 8000 → 2000
        XCTAssertEqual(request.targetLongSide(for: info(640, 480)), 640) // small images stay as they are
    }

    func testExactSizeOverridesTheViewport() {
        var request = ImageLoader.Request(url: URL(fileURLWithPath: "/x.jpg"), viewportPixels: CGSize(width: 2000, height: 1000),
                                          wantsHDR: false, screenSpace: nil)
        request.exactLongSide = 4000
        XCTAssertEqual(request.targetLongSide(for: info(4000, 3000)), 4000)
    }
}
