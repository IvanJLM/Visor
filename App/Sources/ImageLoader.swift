import CoreGraphics
import Foundation
import ImageIO

/// Decodes images off the main thread for one window.
///
/// Memory rule: at most two bitmaps exist per window, the one on screen and
/// one prefetched neighbour. Only the latest request matters: when the user
/// moves on, stale requests are dropped before they decode anything.
final class ImageLoader: @unchecked Sendable {
    enum Result {
        case image(DecodedImage)
        case animated(ImageInfo)
        case failed
    }

    struct Request {
        let url: URL
        /// Long side, in pixels, of the area the image must fill; the decoded
        /// bitmap is no larger than the image shown there.
        let viewportPixels: CGSize
        /// Exact long side wanted, overriding the fit computed from the viewport.
        var exactLongSide: Int?
        let wantsHDR: Bool
        /// Color space of the display the window is on.
        let screenSpace: CGColorSpace?

        func targetLongSide(for info: ImageInfo) -> Int {
            if let exactLongSide { return exactLongSide }
            let w = CGFloat(info.pixelWidth), h = CGFloat(info.pixelHeight)
            let scale = min(1, viewportPixels.width / w, viewportPixels.height / h)
            return Int((CGFloat(info.longSide) * scale).rounded(.up))
        }
    }

    /// One queue for every window: decodes never run in parallel, so peak
    /// memory and the system's scaling buffers stay at one image's worth.
    private static let queue = DispatchQueue(label: "com.ivanjlm.visor.decode", qos: .userInitiated)
    private var queue: DispatchQueue { Self.queue }
    private let lock = NSLock()
    private var generation = 0
    private var prefetched: DecodedImage?
    private var _prefetchEnabled = true
    /// Only the window in front prefetches; others keep a single bitmap.
    var prefetchEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _prefetchEnabled }
        set { lock.lock(); _prefetchEnabled = newValue; if !newValue { prefetched = nil }; lock.unlock() }
    }

    private func nextGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == value
    }

    /// Takes the prefetched bitmap if it is the right file and big enough,
    /// and always empties the slot so it never outlives one navigation.
    private func takePrefetched(_ url: URL, longSide: Int) -> DecodedImage? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = prefetched else { return nil }
        prefetched = nil
        guard hit.info.url == url else { return nil }
        let have = max(hit.image.width, hit.image.height)
        return (have >= longSide || hit.isFullResolution) ? hit : nil
    }

    /// True when the slot already holds `url` with enough pixels.
    private func hasPrefetched(_ url: URL, longSide: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let hit = prefetched, hit.info.url == url else { return false }
        return max(hit.image.width, hit.image.height) >= longSide || hit.isFullResolution
    }

    private func storePrefetched(_ image: DecodedImage) {
        lock.lock(); defer { lock.unlock() }
        prefetched = image
    }

    #if DEBUG
    /// Waits until every decode already queued has run (tests only).
    func waitUntilIdle() { queue.sync {} }
    #endif

    #if VISOR_BENCH
    var debugGeneration: Int { lock.lock(); defer { lock.unlock() }; return generation }
    #endif

    /// Cancels pending work and frees the prefetched bitmap.
    func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        prefetched = nil
    }

    func load(_ request: Request, completion: @escaping @MainActor (Result) -> Void) {
        let ticket = nextGeneration()
        queue.async { [self] in
            guard isCurrent(ticket) else { return }
            let result: Result = autoreleasepool {
                guard let source = ImageDecoder.source(for: request.url),
                      let info = ImageDecoder.info(for: request.url, source: source, checkGainMap: request.wantsHDR)
                else { return .failed }
                if info.isAnimated { return .animated(info) }
                let longSide = request.targetLongSide(for: info)
                if let hit = takePrefetched(request.url, longSide: longSide) { return .image(hit) }
                guard isCurrent(ticket) else { return .failed }
                guard let decoded = ImageDecoder.decode(source: source, info: info, maxPixel: longSide,
                                                        wantsHDR: request.wantsHDR,
                                                        screenSpace: request.screenSpace)
                else { return .failed }
                return .image(decoded)
            }
            DispatchQueue.main.async {
                guard self.isCurrent(ticket) else { return }
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    /// Decodes a neighbour in the background so the next arrow press is instant.
    func prefetch(_ request: Request) {
        lock.lock()
        let ticket = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(ticket), prefetchEnabled else { return }
            autoreleasepool {
                guard let source = ImageDecoder.source(for: request.url),
                      let info = ImageDecoder.info(for: request.url, source: source, checkGainMap: request.wantsHDR),
                      !info.isAnimated
                else { return }
                // Focus changes and zoom refinements ask again for the same
                // neighbour: decode it only once.
                let longSide = request.targetLongSide(for: info)
                guard !hasPrefetched(request.url, longSide: longSide),
                      let decoded = ImageDecoder.decode(source: source, info: info, maxPixel: longSide,
                                                        wantsHDR: request.wantsHDR,
                                                        screenSpace: request.screenSpace)
                else { return }
                if prefetchEnabled { storePrefetched(decoded) }
            }
        }
    }
}

/// Plays GIF, APNG, animated WebP and HEICS frame by frame with ImageIO's own
/// player: one frame in memory at a time, timing taken from the file.
@MainActor
final class AnimationPlayer {
    private var stopped = false

    init(url: URL, onFrame: @escaping @MainActor (CGImage) -> Void) {
        let status = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, image, stop in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { stop.pointee = true; return }
                onFrame(image)
            }
        }
        if status != noErr { stopped = true }
    }

    func stop() { stopped = true }
}
