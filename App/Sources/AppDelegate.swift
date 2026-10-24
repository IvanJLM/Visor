import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [ImageWindowController] = []
    /// Launched by the install script to become the default image viewer.
    private let settingDefault = CommandLine.arguments.contains("--make-default")

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            // Keep the menus to what Visor actually does.
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
            "NSFullScreenMenuItemEverywhere": false,
            "NSQuitAlwaysKeepsWindows": false,
        ])
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if VISOR_BENCH
        Benchmark.startIfRequested(delegate: self)
        if Benchmark.isRequested { return }
        #endif
        if settingDefault {
            Task { await DefaultViewer.makeDefault(quitWhenDone: true) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openImage(url) }
    }

    /// Launched from the Dock or Spotlight without a file: ask for one.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        #if VISOR_BENCH
        if Benchmark.isRequested { return false }
        #endif
        return !settingDefault
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showOpenPanel(nil)
        return true
    }

    /// Visor runs only while an image is open, so it uses no memory otherwise.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !settingDefault }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @discardableResult
    func openImage(_ url: URL) -> ImageWindowController {
        if let existing = controllers.first(where: { $0.currentURL == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = ImageWindowController(cascadeFrom: NSApp.keyWindow ?? controllers.last?.window)
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        controller.open(url)
        #if !VISOR_BENCH
        if controllers.count == 1 && !settingDefault {
            // Ask after the first image is on screen, never in front of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { DefaultViewer.offerOnFirstLaunch() }
        }
        #endif
        return controller
    }

    @objc func showOpenPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls { openImage(url) }
        } else if controllers.isEmpty {
            NSApp.terminate(nil)
        }
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "A minimal, native image viewer for Apple Silicon Macs.\nInspired by qView. Free and open source under the MIT License.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "github.com/IvanJLM/Visor", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: "https://github.com/IvanJLM/Visor")!,
        ]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
