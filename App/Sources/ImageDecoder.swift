import CoreGraphics
import Foundation
import ImageIO

/// What Visor knows about a file before decoding any pixels (header read only).
struct ImageInfo {
    let url: URL
    /// Size after applying the EXIF orientation, in pixels.
    let pixelWidth: Int
    let pixelHeight: Int
    let isAnimated: Bool
    let hasGainMap: Bool
    /// How the stored pixels must be turned to show the image upright (EXIF).
    var storedOrientation = ViewOrientation.identity

    var longSide: Int { max(pixelWidth, pixelHeight) }
}

/// A decoded bitmap ready to hand to Core Animation.
struct DecodedImage {
    let info: ImageInfo
    let image: CGImage
    /// True when the bitmap holds every pixel of the file (no downsampling).
    var isFullResolution: Bool { max(image.width, image.height) >= min(info.longSide, ImageDecoder.maxSide) }
    var isHDR: Bool
}

/// All decoding goes through ImageIO, the system codecs (hardware-accelerated
/// HEIC/JPEG on Apple Silicon). Nothing is cached by ImageIO: Visor decides
/// exactly which bitmaps stay in memory.
enum ImageDecoder {
    /// Core Animation's largest texture side on Apple Silicon.
    static let maxSide = 16384

    /// Every type identifier ImageIO can decode on this Mac.
    static let decodableTypes: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])

    private static let animatableTypes: Set<String> = [
        "com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics", "public.avis",
    ]

    static func source(for url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    static func info(for url: URL, source: CGImageSource, checkGainMap: Bool) -> ImageInfo? {
        guard CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = props[kCGImagePropertyPixelWidth] as? Int,
              var height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation >= 5 && orientation <= 8 { swap(&width, &height) }

        let type = (CGImageSourceGetType(source) as String?) ?? ""
        let animated = CGImageSourceGetCount(source) > 1 && animatableTypes.contains(type)

        var gainMap = false
        if checkGainMap && !animated {
            gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
                || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        }
        return ImageInfo(url: url, pixelWidth: width, pixelHeight: height, isAnimated: animated, hasGainMap: gainMap,
                         storedOrientation: ViewOrientation(exif: orientation))
    }

    /// Decodes the image with its long side at most `maxPixel` pixels, keeping
    /// the original bit depth and color profile. When the display can show
    /// HDR and the file carries a gain map, the result is an HDR bitmap.
    /// `screenSpace` is the color space of the display that will show the
    /// image; see `owned(_:screenSpace:)`.
    static func decode(source: CGImageSource, info: ImageInfo, maxPixel: Int, wantsHDR: Bool,
                       screenSpace: CGColorSpace?) -> DecodedImage? {
        #if DEBUG
        decodeCount.add()
        #endif
        let target = max(1, min(maxPixel, info.longSide, maxSide))
        let decodeHDR = wantsHDR && info.hasGainMap
        if target >= info.longSide && !decodeHDR {
            return decodeFullSize(source: source, info: info, screenSpace: screenSpace)
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if decodeHDR {
            options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
        }
        guard let raw = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let colorSpaceIsHDR = raw.colorSpace.map { CGColorSpaceUsesITUR_2100TF($0) } ?? false
        let isHDR = (decodeHDR && raw.contentHeadroom > 1) || colorSpaceIsHDR
        let image = owned(raw, screenSpace: isHDR ? nil : screenSpace)
        return DecodedImage(info: info, image: image, isHDR: isHDR)
    }

    /// Every pixel of the file, without asking ImageIO for a full-size
    /// "thumbnail": that path decodes the image and then makes a scaled copy
    /// of the same size, so with Visor's own copy three bitmaps of the whole
    /// image existed at once. Here the decoded pixels go straight into
    /// Visor's copy, turned upright on the way (EXIF orientation).
    private static func decodeFullSize(source: CGImageSource, info: ImageInfo, screenSpace: CGColorSpace?) -> DecodedImage? {
        guard let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let isHDR = raw.colorSpace.map { CGColorSpaceUsesITUR_2100TF($0) } ?? false
        let image = owned(raw, screenSpace: isHDR ? nil : screenSpace, orientation: info.storedOrientation)
        return DecodedImage(info: info, image: image, isHDR: isHDR)
    }

    #if DEBUG
    /// Number of decodes, for the tests.
    static let decodeCount = Counter()
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    #endif

    /// Copies ImageIO's bitmap into one Visor owns, pixel for pixel.
    ///
    /// 8-bit images are converted to the display's own color space, the same
    /// ColorSync conversion Core Animation would otherwise run on every
    /// image it shows. Done here, once and off the main thread, Core
    /// Animation can show the bitmap as is: no second converted copy of each
    /// image, which the system then keeps cached and resident. Higher bit
    /// depths and HDR keep their own color space and precision. CMYK, Lab and
    /// indexed images always become RGB.
    /// `orientation` turns the pixels upright on the way (only needed when
    /// ImageIO has not already done it).
    static func owned(_ image: CGImage, screenSpace: CGColorSpace?, orientation: ViewOrientation = .identity) -> CGImage {
        let (transform, width, height) = orientation.drawTransform(width: image.width, height: image.height)
        if let screenSpace, image.bitsPerComponent <= 8, screenSpace.model == .rgb,
           let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: screenSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            context.interpolationQuality = .none
            context.concatenate(transform)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let converted = context.makeImage() { return converted }
        }
        return redraw(image, width: width, height: height, transform: transform) ?? image
    }

    /// Draws `image` into a new bitmap of the given size, after `transform`.
    /// Keeps the bit depth, the color space (when Core Graphics can draw into
    /// it) and the HDR headroom.
    static func redraw(_ image: CGImage, width: Int, height: Int, transform: CGAffineTransform) -> CGImage? {
        let highDepth = image.bitsPerComponent > 8
        let floats = image.bitmapInfo.contains(.floatComponents)
        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb && space.model != .monochrome {
            space = CGColorSpace(name: CGColorSpace.displayP3)!
        }
        let context: CGContext?
        if floats {
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder16Little.rawValue)
        } else if highDepth && space.model == .monochrome && image.alphaInfo == .none {
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        } else if highDepth {
            // Core Graphics has no 16-bit gray with alpha: such images become RGB.
            let rgb = space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: rgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        } else if space.model == .monochrome && image.alphaInfo == .none {
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else {
            let rgb = space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard let context else { return nil }
        context.interpolationQuality = .none
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { return nil }
        let headroom = image.contentHeadroom
        if headroom > 1, let tagged = CGImageCreateCopyWithContentHeadroom(headroom, result) {
            return tagged
        }
        return result
    }
}

/// The 8 ways to show an image upright: an optional horizontal mirror applied
/// first, then 0-3 clockwise quarter turns.
struct ViewOrientation: Equatable {
    var quarterTurns = 0
    var mirrored = false

    static let identity = ViewOrientation()
    var isIdentity: Bool { quarterTurns == 0 && !mirrored }
    var swapsAxes: Bool { quarterTurns % 2 == 1 }

    /// The result of applying `self` and then `next`.
    func then(_ next: ViewOrientation) -> ViewOrientation {
        // A mirror after a rotation equals the inverse rotation after a mirror.
        let turns = next.mirrored ? (next.quarterTurns - quarterTurns) : (quarterTurns + next.quarterTurns)
        return ViewOrientation(quarterTurns: ((turns % 4) + 4) % 4, mirrored: mirrored != next.mirrored)
    }

    static let rotateRight = ViewOrientation(quarterTurns: 1, mirrored: false)
    static let rotateLeft = ViewOrientation(quarterTurns: 3, mirrored: false)
    static let flipHorizontal = ViewOrientation(quarterTurns: 0, mirrored: true)
    static let flipVertical = ViewOrientation(quarterTurns: 2, mirrored: true)

    /// The transform that draws a `width` × `height` bitmap in this
    /// orientation into a Core Graphics context (y up), with the size of
    /// that context.
    func drawTransform(width: Int, height: Int) -> (CGAffineTransform, Int, Int) {
        if isIdentity { return (.identity, width, height) }
        let outW = swapsAxes ? height : width
        let outH = swapsAxes ? width : height
        // Build it from the output back: move to the centre of the output,
        // turn (clockwise on screen is a negative angle with y up), mirror,
        // move back.
        var t = CGAffineTransform(translationX: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        t = t.rotated(by: -CGFloat(quarterTurns) * .pi / 2)
        if mirrored { t = t.scaledBy(x: -1, y: 1) }
        t = t.translatedBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        return (t, outW, outH)
    }

    /// This orientation as a transform about the image centre, in
    /// coordinates where y points down (so a positive angle is clockwise).
    var transform: CGAffineTransform {
        let mirror = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return mirror.concatenating(CGAffineTransform(rotationAngle: CGFloat(quarterTurns) * .pi / 2))
    }

    /// The transform for a layer whose geometry has y pointing down
    /// (`yDown`) or up: a turn that is clockwise on screen either way.
    func layerTransform(yDown: Bool) -> CGAffineTransform {
        if yDown { return transform }
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        return flip.concatenating(transform).concatenating(flip)
    }
}

extension ViewOrientation {
    /// The EXIF / TIFF orientation tag (1-8) as the turn that shows the
    /// stored pixels upright.
    init(exif: Int) {
        switch exif {
        case 2: self.init(quarterTurns: 0, mirrored: true)
        case 3: self.init(quarterTurns: 2, mirrored: false)
        case 4: self.init(quarterTurns: 2, mirrored: true)
        case 5: self.init(quarterTurns: 3, mirrored: true)
        case 6: self.init(quarterTurns: 1, mirrored: false)
        case 7: self.init(quarterTurns: 1, mirrored: true)
        case 8: self.init(quarterTurns: 3, mirrored: false)
        default: self.init()
        }
    }
}
