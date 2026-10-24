// Generates a varied set of test images (JPEG 12/48/108 MP with EXIF
// orientations, HEIC, 16-bit PNG, TIFF, CMYK, grayscale, animated GIF, AVIF
// and an HDR HEIC with a gain map) for scripts/benchmark.sh.
// Usage: swiftc -O scripts/generate-test-images.swift -o /tmp/gen && /tmp/gen /path/to/empty/folder

import Foundation
import ImageIO
import CoreGraphics
import CoreImage
import UniformTypeIdentifiers

let out = CommandLine.arguments[1]
func path(_ n: String) -> URL { URL(fileURLWithPath: out).appendingPathComponent(n) }
func write(_ img: CGImage, _ name: String, _ type: UTType, _ props: [CFString: Any] = [:]) {
    let d = CGImageDestinationCreateWithURL(path(name) as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, props as CFDictionary)
    if !CGImageDestinationFinalize(d) { print("FAILED", name) }
}
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// Photographic-ish content: gradients, circles, text-like stripes and noise.
func photo(_ w: Int, _ h: Int, seed: UInt32, space: CGColorSpace = p3, bpc: Int = 8) -> CGImage {
    let info = bpc == 16 ? (CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bpc, bytesPerRow: 0, space: space, bitmapInfo: info)!
    var r = seed &* 2654435761
    func rnd() -> CGFloat { r = r &* 1664525 &+ 1013904223; return CGFloat(r >> 8) / CGFloat(1 << 24) }
    let g = CGGradient(colorsSpace: space, colors: [CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 1), CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 1)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
    for _ in 0..<60 {
        ctx.setFillColor(CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 0.5))
        let s = rnd() * CGFloat(min(w, h)) * 0.4
        ctx.fillEllipse(in: CGRect(x: rnd() * CGFloat(w), y: rnd() * CGFloat(h), width: s, height: s))
    }
    // Noise so codecs work as hard as on real photos.
    if bpc == 8, let data = ctx.data {
        let p = data.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        for y in 0..<h { for x in 0..<w {
            r = r &* 1664525 &+ 1013904223
            let n = Int(r >> 28) - 8
            let o = y * bpr + x * 4
            p[o] = UInt8(clamping: Int(p[o]) + n); p[o+1] = UInt8(clamping: Int(p[o+1]) + n); p[o+2] = UInt8(clamping: Int(p[o+2]) + n)
        } }
    }
    // An "F" marker in the top-left so orientation mistakes are visible.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    let u = CGFloat(min(w, h)) / 10
    ctx.fill(CGRect(x: u * 0.5, y: CGFloat(h) - u * 4.5, width: u * 0.6, height: u * 4))
    ctx.fill(CGRect(x: u * 0.5, y: CGFloat(h) - u * 1.1, width: u * 2.5, height: u * 0.6))
    ctx.fill(CGRect(x: u * 0.5, y: CGFloat(h) - u * 2.6, width: u * 1.8, height: u * 0.6))
    return ctx.makeImage()!
}

let which = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "all"
if which == "all" || which == "jpeg" {
    let orients = [1, 1, 6, 1, 3, 1, 8, 1]
    for i in 0..<40 {
        let w = i % 5 == 0 ? 3024 : 4032, h = i % 5 == 0 ? 4032 : 3024
        write(photo(w, h, seed: UInt32(i + 1)), String(format: "IMG_%04d.jpg", i + 1), .jpeg,
              [kCGImageDestinationLossyCompressionQuality: 0.9, kCGImagePropertyOrientation: orients[i % orients.count]])
    }
}
if which == "all" || which == "big" {
    for i in 0..<4 { write(photo(8064, 6048, seed: UInt32(100 + i)), String(format: "IMG_48MP_%02d.jpg", i + 1), .jpeg, [kCGImageDestinationLossyCompressionQuality: 0.9]) }
    write(photo(12000, 9000, seed: 200), "Panorama_108MP.jpg", .jpeg, [kCGImageDestinationLossyCompressionQuality: 0.85])
}
if which == "all" || which == "heic" {
    for i in 0..<10 { write(photo(4032, 3024, seed: UInt32(300 + i)), String(format: "IMG_%04d.heic", 100 + i), .heic, [kCGImageDestinationLossyCompressionQuality: 0.8]) }
}
if which == "all" || which == "misc" {
    for i in 0..<4 { write(photo(3000, 2000, seed: UInt32(400 + i), bpc: 16), String(format: "Render_16bit_%02d.png", i + 1), .png) }
    for i in 0..<4 { write(photo(1920, 1080, seed: UInt32(500 + i), space: srgb), String(format: "Screenshot_%02d.png", i + 1), .png) }
    for i in 0..<2 { write(photo(2400, 1600, seed: UInt32(600 + i)), String(format: "Scan_%02d.tiff", i + 1), .tiff) }
    // CMYK JPEG
    let cmyk = CGColorSpace(name: CGColorSpace.genericCMYK)!
    let c = CGContext(data: nil, width: 2000, height: 1400, bitsPerComponent: 8, bytesPerRow: 0, space: cmyk, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    c.draw(photo(2000, 1400, seed: 700, space: srgb), in: CGRect(x: 0, y: 0, width: 2000, height: 1400))
    write(c.makeImage()!, "Print_CMYK.jpg", .jpeg, [kCGImageDestinationLossyCompressionQuality: 0.9])
    // Grayscale
    let gray = CGContext(data: nil, width: 2000, height: 1400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    gray.draw(photo(2000, 1400, seed: 701, space: srgb), in: CGRect(x: 0, y: 0, width: 2000, height: 1400))
    write(gray.makeImage()!, "BW_gray.jpg", .jpeg)
    // Tiny icon to test pixel-exact display
    write(photo(64, 64, seed: 702, space: srgb), "tiny_64.png", .png)
    // Animated GIF
    for a in 0..<2 {
        let d = CGImageDestinationCreateWithURL(path("Anim_\(a + 1).gif") as CFURL, UTType.gif.identifier as CFString, 24, nil)!
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in 0..<24 {
            CGImageDestinationAddImage(d, photo(480, 360, seed: UInt32(800 + a * 50 + f), space: srgb), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
        }
        CGImageDestinationFinalize(d)
    }
    // AVIF if the encoder exists
    if (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains("public.avif") {
        write(photo(3000, 2000, seed: 900), "Photo.avif", UTType("public.avif")!, [kCGImageDestinationLossyCompressionQuality: 0.7])
    } else { print("no AVIF encoder") }
}
if which == "all" || which == "hdr" {
    // HDR HEIC with gain map: highlights at 4x SDR white.
    let w = 3000, h = 2000
    let ext = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0, space: ext,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    ctx.draw(photo(w, h, seed: 950), in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(colorSpace: ext, components: [4, 4, 4, 1])!)
    ctx.fillEllipse(in: CGRect(x: 1000, y: 600, width: 1000, height: 800))
    let hdr = CIImage(cgImage: ctx.makeImage()!)
    let ci = CIContext()
    do {
        try ci.writeHEIFRepresentation(of: hdr.applyingFilter("CIToneMapHeadroom", parameters: ["inputTargetHeadroom": 1.0]), to: path("HDR_gainmap.heic"), format: .RGBA8, colorSpace: p3,
                                       options: [CIImageRepresentationOption.hdrImage: hdr])
    } catch { print("HDR write failed", error) }
}
print("done")
