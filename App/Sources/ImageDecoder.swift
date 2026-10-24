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
        if orientation >= 5 { swap(&width, &height) }

        let type = (CGImageSourceGetType(source) as String?) ?? ""
        let animated = CGImageSourceGetCount(source) > 1 && animatableTypes.contains(type)

        var gainMap = false
        if checkGainMap && !animated {
            gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
                || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        }
        return ImageInfo(url: url, pixelWidth: width, pixelHeight: height, isAnimated: animated, hasGainMap: gainMap)
    }

    /// Decodes the image with its long side at most `maxPixel` pixels, keeping
    /// the original bit depth and color profile. When the display can show
    /// HDR and the file carries a gain map, the result is an HDR bitmap.
    /// `screenSpace` is the color space of the display that will show the
    /// image; see `owned(_:screenSpace:)`.
    static func decode(source: CGImageSource, info: ImageInfo, maxPixel: Int, wantsHDR: Bool,
                       screenSpace: CGColorSpace?) -> DecodedImage? {
        let target = max(1, min(maxPixel, info.longSide, maxSide))
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let decodeHDR = wantsHDR && info.hasGainMap
        if decodeHDR {
            options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
        }
        guard let raw = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let colorSpaceIsHDR = raw.colorSpace.map { CGColorSpaceUsesITUR_2100TF($0) } ?? false
        let isHDR = (decodeHDR && raw.contentHeadroom > 1) || colorSpaceIsHDR
        let image = owned(raw, screenSpace: isHDR ? nil : screenSpace)
        return DecodedImage(info: info, image: image, isHDR: isHDR)
    }

    /// Copies ImageIO's bitmap into one Visor owns, pixel for pixel.
    ///
    /// 8-bit images are converted to the display's own color space, the same
    /// ColorSync conversion Core Animation would otherwise run on every
    /// image it shows. Done here, once and off the main thread, Core
    /// Animation can show the bitmap as is: no second converted copy of each
    /// image, which the system then keeps cached and resident. Higher bit
    /// depths and HDR keep their own color space and precision. CMYK, Lab and
    /// indexed images always become RGB.
    static func owned(_ image: CGImage, screenSpace: CGColorSpace?) -> CGImage {
        if let screenSpace, image.bitsPerComponent <= 8, screenSpace.model == .rgb,
           let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: screenSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let converted = context.makeImage() { return converted }
        }
        return redraw(image, width: image.width, height: image.height, transform: .identity) ?? image
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
        } else if highDepth {
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
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

    /// Returns a new bitmap of `image` shown in this orientation.
    func apply(to image: CGImage) -> CGImage? {
        if isIdentity { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let outW = swapsAxes ? image.height : image.width
        let outH = swapsAxes ? image.width : image.height
        // Core Graphics has y pointing up, so a clockwise turn on screen is a
        // negative angle here. Build the transform from the output back:
        // move to the centre of the output, rotate, mirror, move back.
        var t = CGAffineTransform(translationX: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        t = t.rotated(by: -CGFloat(quarterTurns) * .pi / 2)
        if mirrored { t = t.scaledBy(x: -1, y: 1) }
        t = t.translatedBy(x: -w / 2, y: -h / 2)
        return ImageDecoder.redraw(image, width: outW, height: outH, transform: t)
    }
}
