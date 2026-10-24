import AppKit
import QuartzCore

/// Callbacks from the canvas to the window controller.
@MainActor
protocol ImageCanvasDelegate: AnyObject {
    func canvasZoomChanged(_ canvas: ImageCanvas)
    func canvasRequestsPrevious(_ canvas: ImageCanvas)
    func canvasRequestsNext(_ canvas: ImageCanvas)
    func canvasRequestsFirst(_ canvas: ImageCanvas)
    func canvasRequestsLast(_ canvas: ImageCanvas)
    func canvas(_ canvas: ImageCanvas, didReceiveDrop url: URL)
}

/// Shows one bitmap in a layer. Core Animation scales it on the GPU and color
/// matches it to the display; the view never draws on the CPU.
final class ImageLayerView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: CGImage?, hdr: Bool) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if #available(macOS 26.0, *) {
            layer.preferredDynamicRange = hdr ? .high : .standard
        } else {
            layer.wantsExtendedDynamicRangeContent = hdr
        }
        layer.contents = image
        CATransaction.commit()
    }

    var currentImage: CGImage? {
        guard let contents = layer?.contents else { return nil }
        return (contents as! CGImage)
    }

    /// Nearest-neighbour when an image pixel covers 3+ screen pixels, so
    /// zoomed-in pixels stay crisp instead of blurring.
    func setPixelated(_ pixelated: Bool) {
        let filter: CALayerContentsFilter = pixelated ? .nearest : .linear
        if layer?.magnificationFilter != filter {
            layer?.magnificationFilter = filter
        }
    }
}

/// Keeps the image centred when it is smaller than the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let frame = doc.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}

/// Native scroll view with pinch-to-zoom, drag-to-pan, mouse-wheel zoom and
/// double-click to toggle between fit and actual pixels.
final class ImageCanvas: NSScrollView {
    weak var canvasDelegate: ImageCanvasDelegate?
    let imageView = ImageLayerView(frame: .zero)

    /// Image size in pixels as shown (after rotation). Zero when empty.
    private(set) var imagePixelSize: CGSize = .zero
    /// True while the image follows the window size.
    private(set) var isFitting = true
    private var dragOrigin: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let clip = CenteringClipView(frame: frame)
        clip.drawsBackground = false
        contentView = clip
        documentView = imageView
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .automatic
        verticalScrollElasticity = .automatic
        allowsMagnification = true
        drawsBackground = true
        backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        usesPredominantAxisScrolling = false
        registerForDraggedTypes([.fileURL])
        #if VISOR_BENCH
        Benchmark.liveCanvases += 1
        #endif

        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyStarted),
                                               name: NSScrollView.willStartLiveMagnifyNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    #if VISOR_BENCH
    deinit { Benchmark.liveCanvases -= 1 }
    #endif

    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Sets the image size. Magnification 1 shows one image pixel per screen
    /// pixel, so the document is the pixel size divided by the backing scale.
    func setImagePixelSize(_ size: CGSize, refit: Bool) {
        imagePixelSize = size
        let scale = backingScale
        imageView.frame = NSRect(x: 0, y: 0, width: max(1, size.width / scale), height: max(1, size.height / scale))
        updateMagnificationLimits()
        if refit { zoomToFit() } else { notifyZoom() }
    }

    var fitMagnification: CGFloat {
        let doc = imageView.frame.size
        let view = contentSize
        guard doc.width > 0, doc.height > 0, view.width > 0, view.height > 0 else { return 1 }
        // Never enlarge small images past their real pixels when fitting.
        return min(1, min(view.width / doc.width, view.height / doc.height))
    }

    private func updateMagnificationLimits() {
        minMagnification = max(0.01, min(fitMagnification, 1) / 4)
        maxMagnification = 64
    }

    /// Screen pixels needed for the long side of the image at the current zoom.
    var displayedLongSidePixels: Int {
        Int((max(imagePixelSize.width, imagePixelSize.height) * magnification).rounded(.up))
    }

    func zoomToFit() {
        isFitting = true
        updateMagnificationLimits()
        magnification = fitMagnification
        notifyZoom()
    }

    func zoomToActualPixels(centeredAt point: NSPoint? = nil) {
        setZoom(1, centeredAt: point)
    }

    func zoom(by factor: CGFloat, centeredAt point: NSPoint? = nil) {
        setZoom(magnification * factor, centeredAt: point)
    }

    private func setZoom(_ value: CGFloat, centeredAt point: NSPoint?) {
        let clamped = min(max(value, minMagnification), maxMagnification)
        let center = point ?? NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        // setMagnification re-tiles the view, and tile() puts the fit back
        // while the image is fitting: leave that state first.
        isFitting = false
        setMagnification(clamped, centeredAt: center)
        isFitting = abs(clamped - fitMagnification) < 0.0001
        notifyZoom()
    }

    private func notifyZoom() {
        updatePixelation()
        canvasDelegate?.canvasZoomChanged(self)
    }

    /// An image pixel covering 3+ device pixels is shown as a sharp block.
    private func updatePixelation() {
        let bitmapWidth = CGFloat(max(1, imageView.currentImage?.width ?? 1))
        imageView.setPixelated(magnification * imagePixelSize.width / bitmapWidth >= 3)
    }

    /// Shows a bitmap of the current image (any resolution of it) and keeps
    /// the sharp-pixels filter right for that resolution.
    func display(_ image: CGImage?, hdr: Bool) {
        imageView.show(image, hdr: hdr)
        updatePixelation()
    }

    @objc private func liveMagnifyStarted(_ note: Notification) {
        // Same as setZoom: a pinch must not be undone by tile().
        isFitting = false
    }

    @objc private func liveMagnifyEnded(_ note: Notification) {
        isFitting = abs(magnification - fitMagnification) < 0.0001
        notifyZoom()
    }

    override func tile() {
        super.tile()
        guard imagePixelSize != .zero else { return }
        updateMagnificationLimits()
        if isFitting, abs(magnification - fitMagnification) > 0.0001 {
            magnification = fitMagnification
            notifyZoom()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard imagePixelSize != .zero else { return }
        let fitting = isFitting
        setImagePixelSize(imagePixelSize, refit: fitting)
    }

    // MARK: Mouse

    override func scrollWheel(with event: NSEvent) {
        // A mouse wheel (no precise deltas) zooms around the pointer; a
        // trackpad keeps the native two-finger scroll.
        if !event.hasPreciseScrollingDeltas && event.deltaY != 0 {
            let point = contentView.convert(event.locationInWindow, from: nil)
            zoom(by: pow(1.15, event.deltaY), centeredAt: point)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let point = contentView.convert(event.locationInWindow, from: nil)
            if isFitting && fitMagnification < 1 { zoomToActualPixels(centeredAt: point) } else { zoomToFit() }
            return
        }
        if canPan {
            dragOrigin = event.locationInWindow
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let now = event.locationInWindow
        let dx = (now.x - origin.x) / magnification
        let dy = (now.y - origin.y) / magnification
        dragOrigin = now
        var bounds = contentView.bounds
        bounds.origin.x -= dx
        bounds.origin.y += dy // flipped document
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if dragOrigin != nil {
            dragOrigin = nil
            NSCursor.pop()
        }
    }

    private var canPan: Bool {
        let doc = imageView.frame.size
        let view = contentView.bounds.size
        return doc.width > view.width + 0.5 || doc.height > view.height + 0.5
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else {
            return super.keyDown(with: event)
        }
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        switch Int(key) {
        case NSLeftArrowFunctionKey where plain: canvasDelegate?.canvasRequestsPrevious(self)
        case NSRightArrowFunctionKey where plain: canvasDelegate?.canvasRequestsNext(self)
        case NSHomeFunctionKey: canvasDelegate?.canvasRequestsFirst(self)
        case NSEndFunctionKey: canvasDelegate?.canvasRequestsLast(self)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImageURL(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedImageURL(sender) else { return false }
        canvasDelegate?.canvas(self, didReceiveDrop: url)
        return true
    }

    private func droppedImageURL(_ sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else { return nil }
        return urls.first { FolderScanner.isImage($0) }
    }
}
