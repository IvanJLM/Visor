import AppKit
import UniformTypeIdentifiers

/// One window showing one image at a time, with arrow-key navigation through
/// the other images in the same folder.
@MainActor
final class ImageWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, ImageCanvasDelegate {
    /// The window the user is looking at; the only one that prefetches.
    private static weak var focused: ImageWindowController?
    var onClose: ((ImageWindowController) -> Void)?
    /// Called each time an image reaches the screen (used by the benchmark).
    var onDisplay: ((URL) -> Void)?

    private let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private var chrome: WindowChrome!
    private let loader = ImageLoader()

    private(set) var currentURL: URL?
    private var info: ImageInfo?
    private var orientation = ViewOrientation.identity
    private var animation: AnimationPlayer?
    private var isShowingHDR = false
    private var refineTimer: Timer?
    /// True from a navigation request until its image is on screen.
    private var isLoading = false
    private var errorLabel: NSTextField?

    private var folder: URL?
    private var folderDate: Date?
    private var files: [URL] = []
    private var index = 0
    private var direction = 1
    private var hasAppeared = false
    private weak var cascadeSource: NSWindow?
    /// Where the last window was closed, if Visor remembers one.
    private let restoredFrame = WindowFrameMemory.restored()
    private var isChangingFullScreen = false

    init(cascadeFrom other: NSWindow?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        // The image fills the whole window; the title bar floats over it.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 320, height: 220)
        window.isReleasedWhenClosed = false
        window.backgroundColor = canvas.backgroundColor
        super.init(window: window)
        window.delegate = self
        canvas.canvasDelegate = self
        let container = NSView(frame: canvas.frame)
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
        window.contentView = container
        window.initialFirstResponder = canvas
        chrome = WindowChrome(window: window, container: container)
        cascadeSource = other
        #if VISOR_BENCH
        Benchmark.liveControllers += 1
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Opening

    /// Opens `url` and makes this window's folder the one that contains it.
    func open(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        if parent != folder {
            folder = parent
            files = []
            folderDate = nil
        }
        show(url)
    }

    private var wantsHDR: Bool {
        let screen = window?.screen ?? NSScreen.main
        return (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    }

    private var screenSpace: CGColorSpace? {
        (window?.screen ?? NSScreen.main)?.colorSpace?.cgColorSpace
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Pixel area the image may fill: the window's content area once it is on
    /// screen, otherwise the remembered window or the largest that fits the screen.
    private var viewportPixels: CGSize {
        let scale = backingScale
        if hasAppeared {
            let size = canvas.contentSize
            return CGSize(width: size.width * scale, height: size.height * scale)
        }
        if let restoredFrame {
            return CGSize(width: restoredFrame.width * scale, height: restoredFrame.height * scale)
        }
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return CGSize(width: visible.width * 0.9 * scale, height: visible.height * 0.9 * scale)
    }

    private func show(_ url: URL) {
        currentURL = url
        refineTimer?.invalidate()
        isLoading = true
        let request = ImageLoader.Request(url: url, viewportPixels: viewportPixels, wantsHDR: wantsHDR, screenSpace: screenSpace)
        loader.load(request) { [weak self] result in
            self?.display(result, for: url)
        }
    }

    private func display(_ result: ImageLoader.Result, for url: URL) {
        isLoading = false
        animation?.stop()
        animation = nil
        orientation = .identity
        canvas.imageView.setOrientation(.identity)
        errorLabel?.removeFromSuperview()
        errorLabel = nil

        switch result {
        case .image(let decoded):
            info = decoded.info
            preparedFor = screenSpace
            isShowingHDR = decoded.isHDR
            canvas.setImagePixelSize(CGSize(width: decoded.info.pixelWidth, height: decoded.info.pixelHeight), refit: true)
            canvas.display(decoded.image, hdr: decoded.isHDR)
        case .animated(let info):
            self.info = info
            isShowingHDR = false
            canvas.setImagePixelSize(CGSize(width: info.pixelWidth, height: info.pixelHeight), refit: true)
            canvas.display(nil, hdr: false)
            animation = AnimationPlayer(url: url) { [weak self] frame in
                self?.canvas.display(frame, hdr: false)
            }
        case .failed:
            info = nil
            canvas.display(nil, hdr: false)
            canvas.setImagePixelSize(.zero, refit: true)
            showError()
        }

        if !hasAppeared { appear() }
        updateTitle()
        if window?.styleMask.contains(.fullScreen) == true { NSCursor.setHiddenUntilMouseMoves(true) }
        onDisplay?(url)
        if files.isEmpty { scanFolder() } else { prefetchNeighbour() }
    }

    private func appear() {
        guard let window else { return }
        hasAppeared = true
        takeFocus()
        if let restoredFrame {
            // Same place and size as the last window the user closed.
            window.setFrame(restoredFrame, display: false)
            if let other = cascadeSource, other.isVisible {
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: other.frame.minX, y: other.frame.maxY)))
                if let fitted = WindowFrameMemory.fitted(window.frame, into: NSScreen.screens.map(\.visibleFrame)) {
                    window.setFrame(fitted, display: false)
                }
            }
        } else {
            sizeToImage(window)
        }
        canvas.zoomToFit()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        chrome.show()
    }

    /// First window ever: as large as the image, up to 90 % of the screen.
    private func sizeToImage(_ window: NSWindow) {
        let scale = backingScale
        let visible = (window.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var size = NSSize(width: 640, height: 480)
        if let info {
            let maxW = visible.width * 0.9, maxH = visible.height * 0.9
            let w = CGFloat(info.pixelWidth) / scale, h = CGFloat(info.pixelHeight) / scale
            let fit = min(1, maxW / w, maxH / h)
            size = NSSize(width: max(window.contentMinSize.width, (w * fit).rounded()),
                          height: max(window.contentMinSize.height, (h * fit).rounded()))
        }
        window.setContentSize(size)
        if let other = cascadeSource, other.isVisible {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: other.frame.minX, y: other.frame.maxY)))
        }
        if cascadeSource == nil || !visible.contains(window.frame) {
            window.center()
        }
    }

    private func showError() {
        let label = NSTextField(labelWithString: "This image can’t be opened.")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 15)
        label.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
        ])
        errorLabel = label
    }

    private func updateTitle() {
        guard let window, let url = currentURL else { return }
        window.title = url.lastPathComponent
        window.representedURL = url
        var parts: [String] = []
        if files.count > 1, let position = files.firstIndex(of: url) {
            parts.append("\(position + 1) of \(files.count)")
        }
        if let info {
            let w = orientation.swapsAxes ? info.pixelHeight : info.pixelWidth
            let h = orientation.swapsAxes ? info.pixelWidth : info.pixelHeight
            parts.append("\(w) × \(h)")
        }
        if isShowingHDR { parts.append("HDR") }
        window.subtitle = parts.joined(separator: "  ·  ")
    }

    // MARK: Folder navigation

    private func scanFolder() {
        guard let folder else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let date = FolderScanner.modificationDate(of: folder)
            let list = FolderScanner.images(in: folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.folder == folder else { return }
                    self.files = list
                    self.folderDate = date
                    if let current = self.currentURL, let i = list.firstIndex(of: current) { self.index = i }
                    self.updateTitle()
                    self.prefetchNeighbour()
                }
            }
        }
    }

    /// Re-reads the folder when something was added, removed or renamed.
    private func refreshFolderIfChanged() {
        guard let folder else { return }
        let date = FolderScanner.modificationDate(of: folder)
        guard date != folderDate else { return }
        files = FolderScanner.images(in: folder)
        folderDate = date
        if let current = currentURL, let i = files.firstIndex(of: current) { index = i }
    }

    private func step(_ delta: Int) {
        refreshFolderIfChanged()
        guard files.count > 1 else { return }
        direction = delta >= 0 ? 1 : -1
        index = ((index + delta) % files.count + files.count) % files.count
        show(files[index])
    }

    private func jump(to target: Int) {
        refreshFolderIfChanged()
        guard !files.isEmpty else { return }
        direction = target == 0 ? 1 : -1
        index = target < 0 ? files.count - 1 : 0
        show(files[index])
    }

    private func takeFocus() {
        guard Self.focused !== self else { return }
        Self.focused?.loader.prefetchEnabled = false
        Self.focused = self
        loader.prefetchEnabled = true
        prefetchNeighbour()
    }

    private func prefetchNeighbour() {
        guard files.count > 1, Self.focused === self else { return }
        let next = files[((index + direction) % files.count + files.count) % files.count]
        guard next != currentURL else { return }
        loader.prefetch(ImageLoader.Request(url: next, viewportPixels: viewportPixels, wantsHDR: wantsHDR, screenSpace: screenSpace))
    }

    // MARK: Zoom-dependent resolution

    func canvasZoomChanged(_ canvas: ImageCanvas) {
        refineTimer?.invalidate()
        // Never let a resolution change cancel the image being loaded.
        guard info != nil, animation == nil, !isLoading else { return }
        refineTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refineIfNeeded() }
        }
    }

    /// Re-decodes the current image when the zoom needs more pixels than the
    /// bitmap has, or far fewer (to give memory back after zooming out).
    private func refineIfNeeded() {
        guard !isLoading, let info, let url = currentURL, let current = canvas.imageView.currentImage else { return }
        let have = max(current.width, current.height)
        let full = min(info.longSide, ImageDecoder.maxSide)
        let needed = min(full, canvas.displayedLongSidePixels)
        var target: Int?
        if needed > Int(Double(have) * 1.02), have < full {
            // Past 60 % of the file, decode it whole once rather than in steps.
            target = needed > full * 6 / 10 ? full : needed
        } else if needed * 5 < have * 2 {
            target = needed
        }
        guard let target else { return }
        var request = ImageLoader.Request(url: url, viewportPixels: .zero, wantsHDR: wantsHDR, screenSpace: screenSpace)
        request.exactLongSide = target
        loader.load(request) { [weak self] result in
            guard let self, self.currentURL == url, !self.isLoading, case .image(let decoded) = result else { return }
            self.canvas.display(decoded.image, hdr: decoded.isHDR)
            self.prefetchNeighbour()
        }
    }

    // MARK: ImageCanvasDelegate

    func canvasRequestsPrevious(_ canvas: ImageCanvas) { step(-1) }
    func canvasRequestsNext(_ canvas: ImageCanvas) { step(1) }
    func canvasRequestsFirst(_ canvas: ImageCanvas) { jump(to: 0) }
    func canvasRequestsLast(_ canvas: ImageCanvas) { jump(to: -1) }

    func canvas(_ canvas: ImageCanvas, didReceiveDrop url: URL) {
        open(url)
    }

    // MARK: Actions

    @objc func previousImage(_ sender: Any?) { step(-1) }
    @objc func nextImage(_ sender: Any?) { step(1) }
    @objc func firstImage(_ sender: Any?) { jump(to: 0) }
    @objc func lastImage(_ sender: Any?) { jump(to: -1) }

    @objc func zoomIn(_ sender: Any?) { canvas.zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { canvas.zoom(by: 0.8) }
    @objc func actualSize(_ sender: Any?) { canvas.zoomToActualPixels() }
    @objc func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }

    @objc func rotateLeft(_ sender: Any?) { reorient(.rotateLeft) }
    @objc func rotateRight(_ sender: Any?) { reorient(.rotateRight) }
    @objc func flipHorizontal(_ sender: Any?) { reorient(.flipHorizontal) }
    @objc func flipVertical(_ sender: Any?) { reorient(.flipVertical) }

    /// Turns or mirrors the view on the GPU; the bitmap is not touched.
    private func reorient(_ change: ViewOrientation) {
        guard let info, animation == nil, canvas.imageView.currentImage != nil else { return }
        orientation = orientation.then(change)
        let w = orientation.swapsAxes ? info.pixelHeight : info.pixelWidth
        let h = orientation.swapsAxes ? info.pixelWidth : info.pixelHeight
        canvas.imageView.setOrientation(orientation)
        canvas.setImagePixelSize(CGSize(width: w, height: h), refit: true)
        updateTitle()
    }

    @objc func copy(_ sender: Any?) {
        guard let url = currentURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        // The image data is only produced if another app actually pastes it.
        let provider = PasteboardImageProvider(url: url)
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        pasteboard.writeObjects([item])
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let url = currentURL else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] trashed, error in
            MainActor.assumeIsolated {
                guard let self, error == nil, !trashed.isEmpty else { NSSound.beep(); return }
                self.afterRemoving(url)
            }
        }
    }

    private func afterRemoving(_ url: URL) {
        if let i = files.firstIndex(of: url) {
            files.remove(at: i)
            index = min(i, max(0, files.count - 1))
        }
        folderDate = folder.flatMap { FolderScanner.modificationDate(of: $0) }
        if files.isEmpty {
            window?.close()
        } else {
            show(files[index])
        }
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func openInPreview(_ sender: Any?) {
        guard let url = currentURL,
              let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    override func cancelOperation(_ sender: Any?) {
        if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(flipHorizontal(_:)), #selector(flipVertical(_:)):
            return info != nil && animation == nil
        case #selector(previousImage(_:)), #selector(nextImage(_:)), #selector(firstImage(_:)), #selector(lastImage(_:)):
            return files.count > 1
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)), #selector(zoomToFit(_:)):
            return info != nil
        default:
            return currentURL != nil
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        takeFocus()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        isChangingFullScreen = true
        canvas.backgroundColor = .black
        chrome.suspend()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isChangingFullScreen = false
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isChangingFullScreen = false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isChangingFullScreen = true
        canvas.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isChangingFullScreen = false
        chrome.resume()
        rememberFrame()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        isChangingFullScreen = false
    }

    // The next window opens where this one was last moved or resized to.
    func windowDidMove(_ notification: Notification) {
        rememberFrame()
    }

    func windowDidResize(_ notification: Notification) {
        if window?.inLiveResize == false { rememberFrame() }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberFrame()
    }

    private func rememberFrame() {
        guard hasAppeared, !isChangingFullScreen, let window, !window.styleMask.contains(.fullScreen),
              !window.isMiniaturized else { return }
        WindowFrameMemory.save(window.frame)
    }

    /// Bitmaps are prepared for one display (color profile, HDR), so moving
    /// to another display, or changing its profile, prepares them again.
    func windowDidChangeScreen(_ notification: Notification) {
        reloadForDisplay()
    }

    func windowDidChangeScreenProfile(_ notification: Notification) {
        reloadForDisplay()
    }

    private var preparedFor: CGColorSpace?

    private func reloadForDisplay() {
        guard hasAppeared, !isLoading, let url = currentURL, animation == nil else { return }
        let space = screenSpace
        if let preparedFor, let space, preparedFor == space, !(info?.hasGainMap == true && isShowingHDR != wantsHDR) { return }
        // The prefetched neighbour was prepared for the old display: drop it.
        loader.prefetchEnabled = false
        loader.prefetchEnabled = Self.focused === self
        let zoomed = !canvas.isFitting
        var request = ImageLoader.Request(url: url, viewportPixels: .zero, wantsHDR: wantsHDR, screenSpace: space)
        request.exactLongSide = canvas.imageView.currentImage.map { max($0.width, $0.height) }
        loader.load(request) { [weak self] result in
            guard let self, self.currentURL == url, case .image(let decoded) = result else { return }
            self.preparedFor = space
            self.isShowingHDR = decoded.isHDR
            self.canvas.display(decoded.image, hdr: decoded.isHDR)
            if !zoomed { self.canvas.zoomToFit() }
            self.updateTitle()
        }
    }

    #if VISOR_BENCH
    deinit { Benchmark.liveControllers -= 1 }
    var debugChrome: String { "chromeShown=\(chrome.isShown) timer=\(chrome.hideTimer != nil) titlebarAlpha=\(window?.standardWindowButton(.closeButton)?.superview?.alphaValue ?? -1) insetTop=\(canvas.contentInsets.top)" }
    func debugShowChrome() { chrome.show() }
    var debugFilter: String { canvas.imageView.magnificationFilter.rawValue }
    var debugState: String { "current=\(currentURL?.lastPathComponent ?? "-") loading=\(isLoading) index=\(index)/\(files.count) gen=\(loader.debugGeneration)" }
    #endif

    func windowWillClose(_ notification: Notification) {
        rememberFrame()
        chrome.stop()
        refineTimer?.invalidate()
        animation?.stop()
        animation = nil
        loader.cancelAll()
        canvas.display(nil, hdr: false)
        info = nil
        onClose?(self)
    }
}

/// Supplies PNG/TIFF data for Copy only when another app asks for it.
final class PasteboardImageProvider: NSObject, NSPasteboardItemDataProvider {
    private let url: URL

    init(url: URL) { self.url = url }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let source = ImageDecoder.source(for: url),
              let info = ImageDecoder.info(for: url, source: source, checkGainMap: false),
              let decoded = ImageDecoder.decode(source: source, info: info, maxPixel: info.longSide, wantsHDR: false,
                                                screenSpace: nil)
        else { return }
        let data = NSMutableData()
        let uti = (type == .png ? UTType.png : UTType.tiff).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, uti, 1, nil) else { return }
        CGImageDestinationAddImage(destination, decoded.image, nil)
        if CGImageDestinationFinalize(destination) {
            item.setData(data as Data, forType: type)
        }
    }
}
