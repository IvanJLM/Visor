import AppKit

/// Hides the title bar into the image, as Vids and IINA do: the close,
/// minimize and zoom buttons, the file name and its position in the folder
/// appear while the mouse moves over the window and fade out two seconds
/// after it stops. Nothing runs while the mouse is still: the timer exists
/// only right after the mouse has moved.
@MainActor
final class WindowChrome: NSResponder {
    static let idleDelay: TimeInterval = 2
    /// Height of the band at the top that keeps the buttons visible.
    private static let titleBand: CGFloat = 40

    private weak var window: NSWindow?
    private let shade = TopShade()
    private(set) var hideTimer: Timer?
    private(set) var isShown = true
    /// True in full screen, where macOS manages the title bar itself.
    private var isSuspended = false

    init(window: NSWindow, container: NSView) {
        self.window = window
        super.init()
        shade.frame = NSRect(x: 0, y: container.bounds.height - TopShade.height,
                             width: container.bounds.width, height: TopShade.height)
        shade.autoresizingMask = [.width, .minYMargin]
        container.addSubview(shade)
        container.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var titlebar: NSView? { window?.standardWindowButton(.closeButton)?.superview }

    /// Shows the title bar and starts the countdown to hide it.
    func show() {
        if !isShown && !isSuspended {
            isShown = true
            titlebar?.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                titlebar?.animator().alphaValue = 1
                shade.animator().alphaValue = 1
            }
        }
        restartTimer()
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard isShown, !isSuspended else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            titlebar?.animator().alphaValue = 0
            shade.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.titlebar?.isHidden = true  // no clicks on invisible buttons
            }
        })
    }

    /// Full screen: macOS shows the title bar when the pointer reaches the top.
    func suspend() {
        hideTimer?.invalidate()
        hideTimer = nil
        isSuspended = true
        isShown = true
        titlebar?.isHidden = false
        titlebar?.alphaValue = 1
        shade.alphaValue = 0
    }

    func resume() {
        isSuspended = false
        shade.alphaValue = 1
        show()
    }

    /// The window is closing: no timer outlives it.
    func stop() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func restartTimer() {
        let fire = Date().addingTimeInterval(Self.idleDelay)
        if let timer = hideTimer, timer.isValid {
            timer.fireDate = fire
        } else {
            let timer = Timer(timeInterval: Self.idleDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideIfIdle() }
            }
            timer.tolerance = 0.2  // lets macOS group the wake-up with others
            RunLoop.main.add(timer, forMode: .common)
            hideTimer = timer
        }
    }

    private func hideIfIdle() {
        hideTimer = nil
        guard let window, let content = window.contentView else { return }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if content.bounds.contains(point) && point.y > content.bounds.height - Self.titleBand && !isSuspended {
            // The pointer rests on the buttons: they stay until it moves again,
            // without waking up every two seconds to check.
            return
        }
        hide()
    }

    override func mouseEntered(with event: NSEvent) { show() }
    override func mouseMoved(with event: NSEvent) { show() }
    override func mouseExited(with event: NSEvent) { hide() }
}

/// A soft dark band behind the title bar, so buttons and title read on bright images.
private final class TopShade: NSView {
    static let height: CGFloat = 64

    override init(frame: NSRect) {
        super.init(frame: frame)
        let gradient = CAGradientLayer()
        gradient.colors = [NSColor(white: 0, alpha: 0.45).cgColor, NSColor.clear.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer = gradient
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
