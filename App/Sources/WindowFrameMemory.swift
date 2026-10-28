import AppKit

/// Remembers where the last window was and how big it was, so the next image
/// opens in the same place at the same size.
@MainActor
enum WindowFrameMemory {
    static let key = "LastWindowFrame"

    /// Off in the benchmark and in the tests, which must never move the
    /// user's own window.
    static var defaults: UserDefaults? = {
        #if VISOR_BENCH
        return nil
        #else
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .standard : nil
        #endif
    }()

    static func save(_ frame: NSRect) {
        guard let defaults, frame.width > 0, frame.height > 0 else { return }
        defaults.set(NSStringFromRect(frame), forKey: key)
    }

    /// The saved frame, moved onto a display that is connected now.
    static func restored() -> NSRect? {
        guard let text = defaults?.string(forKey: key) else { return nil }
        return fitted(NSRectFromString(text), into: NSScreen.screens.map(\.visibleFrame))
    }

    /// `frame` kept whole on the display it mostly covers (the first display
    /// if it covers none), shrunk only if that display is smaller.
    static func fitted(_ frame: NSRect, into displays: [NSRect]) -> NSRect? {
        guard frame.width > 0, frame.height > 0, let first = displays.first else { return nil }
        func overlap(_ display: NSRect) -> CGFloat {
            let common = display.intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        let display = displays.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil } ?? first
        var result = frame
        result.size.width = min(frame.width, display.width)
        result.size.height = min(frame.height, display.height)
        result.origin.x = min(max(frame.minX, display.minX), display.maxX - result.width)
        result.origin.y = min(max(frame.minY, display.minY), display.maxY - result.height)
        return result
    }
}
