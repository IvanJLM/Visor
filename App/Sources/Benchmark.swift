#if VISOR_BENCH
import AppKit
import Darwin
import ImageIO
import QuartzCore

/// Stress test compiled only into benchmark builds (-D VISOR_BENCH), never into
/// the installed app. Drives a window through a folder and logs memory and
/// latency so leaks or growth across many images show up.
@MainActor
enum Benchmark {
    nonisolated(unsafe) static var liveControllers = 0
    nonisolated(unsafe) static var liveCanvases = 0
    static var isRequested: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["VISOR_BENCH_DIR"] != nil || env["VISOR_BENCH_SHOW"] != nil
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private static var log: FileHandle?
    private static func say(_ text: String) {
        let line = text + "\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        log?.write(line.data(using: .utf8)!)
    }

    final class Weak { weak var object: AnyObject?; init(_ o: AnyObject) { object = o } }

    /// Opens and closes windows with one more feature each round, and reports
    /// which round stops closed windows from being freed.
    static func windowExperiment(delegate: AppDelegate, image: URL) async {
        // Keeps the app alive: Visor quits when its last window closes.
        let anchor = delegate.openImage(image)
        await sleep(0.5)
        let steps = ["plain", "title+subtitle", "representedURL", "darkAqua", "scrollView", "key+firstResponder", "delegate", "drag types", "fullController"]
        for (n, name) in steps.enumerated() {
            var refs: [Weak] = []
            for _ in 0..<5 {
                autoreleasepool {
                    if name == "fullController" {
                        let others = FolderScanner.images(in: image.deletingLastPathComponent())
                        _ = delegate.openImage(others[Int.random(in: 1..<others.count)])
                        return
                    }
                    let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
                    w.isReleasedWhenClosed = false
                    if n >= 1 { w.title = "x"; w.subtitle = "1 of 2" }
                    if n >= 2 { w.representedURL = image }
                    if n >= 3 { w.appearance = NSAppearance(named: .darkAqua) }
                    var sv: NSScrollView?
                    if n >= 4 { let s = NSScrollView(frame: w.contentLayoutRect); s.allowsMagnification = true; s.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 2000, height: 2000)); w.contentView = s; sv = s }
                    if n >= 7 { sv?.registerForDraggedTypes([.fileURL]) }
                    w.orderFront(nil)
                    if n >= 5 { w.makeKeyAndOrderFront(nil); w.makeFirstResponder(sv) }
                    refs.append(Weak(w))
                }
                await sleep(0.2)
            }
            if name == "fullController" {
                for w in NSApp.windows where w.isVisible && w !== anchor.window { refs.append(Weak(w)) }
            }
            for r in refs { (r.object as? NSWindow)?.close() }
            await sleep(1)
            pumpEvents()
            await sleep(1)
            let alive = refs.filter { $0.object != nil }.count
            say("experiment \(name): \(alive)/\(refs.count) closed windows still alive")
        }
    }

    static func startIfRequested(delegate: AppDelegate) {
        let env = ProcessInfo.processInfo.environment
        if let out = env["VISOR_BENCH_OUT"] {
            FileManager.default.createFile(atPath: out, contents: nil)
            log = FileHandle(forWritingAtPath: out)
        }
        if let show = env["VISOR_BENCH_SHOW"] {
            // Opens one image and reports its window number for screenshots.
            Task { @MainActor in
                let c = delegate.openImage(URL(fileURLWithPath: show))
                await sleep(1.0)
                if let ops = env["VISOR_BENCH_OPS"] {
                    for op in ops.split(separator: ",") {
                        let start = CACurrentMediaTime()
                        switch op {
                        case "actual": c.actualSize(nil)
                        case "fit": c.zoomToFit(nil)
                        case "zoomin": c.zoomIn(nil)
                        case "right": c.rotateRight(nil)
                        case "left": c.rotateLeft(nil)
                        case "flipH": c.flipHorizontal(nil)
                        case "flipV": c.flipVertical(nil)
                        default: break
                        }
                        say(String(format: "op %@: %.2f ms on the main thread, footprint %.1f MB", String(op),
                                   (CACurrentMediaTime() - start) * 1000, footprintMB()))
                        await sleep(0.4)
                    }
                }
                await sleep(0.5)
                say("WINDOW \(c.window?.windowNumber ?? 0) \(c.window?.subtitle ?? "") filter=\(c.debugFilter)")
                if let png = env["VISOR_BENCH_PNG"], let view = c.window?.contentView {
                    let size = view.bounds.size
                    let scale = c.window?.backingScaleFactor ?? 1
                    let space = c.window?.screen?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
                    let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                    ctx.scaleBy(x: scale, y: scale)
                    if view.layer?.isGeometryFlipped == true || view.isFlipped {
                        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
                    }
                    say("root flipped: \(view.layer?.isGeometryFlipped ?? false) view flipped: \(view.isFlipped)")
                    view.layer?.render(in: ctx)
                    if let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: png) as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, image, nil)
                        CGImageDestinationFinalize(dest)
                    }
                    say("PNG written")
                }
                await sleep(Double(env["VISOR_BENCH_HOLD"] ?? "6") ?? 6)
                exit(0)
            }
            return
        }
        if env["WINDOW_EXPERIMENT"] != nil, let dir = env["VISOR_BENCH_DIR"] {
            Task { @MainActor in
                let first = FolderScanner.images(in: URL(fileURLWithPath: dir)).first!
                await windowExperiment(delegate: delegate, image: first)
                exit(0)
            }
            return
        }
        guard let dir = env["VISOR_BENCH_DIR"] else { return }
        let loops = Int(env["VISOR_BENCH_LOOPS"] ?? "3") ?? 3
        Task { @MainActor in
            await run(delegate: delegate, folder: URL(fileURLWithPath: dir), loops: loops)
            say("DONE")
            exit(0)
        }
    }

    private static var waiter: CheckedContinuation<Void, Never>?
    private static weak var debugController: ImageWindowController?

    private static var waitID = 0

    private static func waitForDisplay(timeout: Double = 10) async {
        waitID += 1
        let id = waitID
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiter = c
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated {
                    // Only time out the wait that scheduled this check.
                    if id == waitID, let w = waiter { waiter = nil; say("TIMEOUT waiting for display: \(debugController?.debugState ?? "")"); w.resume() }
                }
            }
        }
    }

    /// Real use always has events flowing (mouse moves, key presses); AppKit
    /// finishes tearing closed windows down while handling them. A benchmark
    /// that only sleeps sends none, so it posts a few no-op events instead.
    static func pumpEvents() {
        for _ in 0..<3 {
            if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    private static func stats(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let s = values.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * q))] }
        return String(format: "n=%d p50=%.1fms p95=%.1fms max=%.1fms", s.count, p(0.5), p(0.95), s.last!)
    }

    private static func run(delegate: AppDelegate, folder: URL, loops: Int) async {
        say("screen color space: \(String(describing: NSScreen.main?.colorSpace?.localizedName)), EDR max \(NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 0), screens \(NSScreen.screens.count)")
        let files = FolderScanner.images(in: folder)
        guard let first = files.first else { say("no images"); return }
        say(String(format: "baseline before window: %.1f MB, %d images", footprintMB(), files.count))

        let t0 = CACurrentMediaTime()
        let controller = delegate.openImage(first)
        debugController = controller
        controller.onDisplay = { _ in
            if let w = waiter { waiter = nil; w.resume() }
        }
        await waitForDisplay()
        say(String(format: "first image on screen: %.1f ms, footprint %.1f MB", (CACurrentMediaTime() - t0) * 1000, footprintMB()))
        await sleep(0.5) // folder scan + prefetch
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        await sleep(0.5)

        // 1. Keyboard path: one right-arrow press must move exactly one image.
        let before = controller.window?.subtitle ?? ""
        NSApp.activate()
        await sleep(0.5)
        say("app active: \(NSApp.isActive), window key: \(controller.window?.isKeyWindow ?? false)")
        if let window = controller.window,
           let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: String(Character(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)),
                                        charactersIgnoringModifiers: String(Character(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)),
                                        isARepeat: false, keyCode: 124) {
            NSApp.postEvent(event, atStart: false)
            await waitForDisplay(timeout: 3)
            await sleep(0.3)
            say("arrow key: '\(before)' -> '\(controller.window?.subtitle ?? "")'")
        }

        if ProcessInfo.processInfo.environment["ONLY_WINDOWS"] == nil {
        // 2. Normal browsing: next image, wait until it is shown, short pause.
        for loop in 1...loops {
            var latencies: [Double] = []
            for _ in 0..<files.count {
                let start = CACurrentMediaTime()
                let before = controller.debugState
                controller.nextImage(nil)
                await waitForDisplay()
                if (CACurrentMediaTime() - start) > 5 { say("  slow step started from: \(before)") }
                latencies.append((CACurrentMediaTime() - start) * 1000)
                await sleep(0.06)
            }
            say(String(format: "browse loop %d: %@ | footprint %.1f MB", loop, stats(latencies), footprintMB()))
        }

        // 3. Key repeat: hold the arrow (a press every 16 ms) through 300 images.
        let startRepeat = CACurrentMediaTime()
        for _ in 0..<300 {
            controller.nextImage(nil)
            await sleep(0.016)
        }
        await sleep(1.0)
        say(String(format: "key repeat x300 in %.1fs | footprint %.1f MB", CACurrentMediaTime() - startRepeat, footprintMB()))

        // 4. Zoom: actual pixels, zoom in 4 steps, back to fit, on 15 images.
        var peak = 0.0
        for _ in 0..<min(15, files.count) {
            controller.nextImage(nil)
            await waitForDisplay()
            controller.actualSize(nil); await sleep(0.4)
            for _ in 0..<4 { controller.zoomIn(nil); await sleep(0.3) }
            peak = max(peak, footprintMB())
            controller.zoomToFit(nil); await sleep(0.4)
            controller.rotateRight(nil); controller.flipHorizontal(nil); await sleep(0.1)
        }
        say(String(format: "zoom/rotate x15: peak %.1f MB, after fit %.1f MB", peak, footprintMB()))

        }
        // 5. Many windows: open 25, then close them again.
        var extra: [ImageWindowController] = []
        for (i, url) in files.prefix(26).enumerated() where i > 0 {
            let c = delegate.openImage(url)
            if c !== controller { extra.append(c) }
            await sleep(0.15)
        }
        say(String(format: "%d windows open: %.1f MB, live controllers %d canvases %d", extra.count + 1, footprintMB(), liveControllers, liveCanvases))
        for c in extra { c.window?.close(); await sleep(0.05) }
        extra.removeAll()
        await sleep(0.5)
        pumpEvents()
        await sleep(1.5)
        say(String(format: "back to 1 window: %.1f MB, live controllers %d canvases %d", footprintMB(), liveControllers, liveCanvases))

        // 6. Idle with one window: footprint must stay flat.
        await sleep(5)
        say(String(format: "after 5 s idle: %.1f MB", footprintMB()))
        if let hold = Double(ProcessInfo.processInfo.environment["VISOR_BENCH_HOLD"] ?? "") {
            say("HOLD pid \(getpid())")
            await sleep(hold)
        }
    }
}
#endif
