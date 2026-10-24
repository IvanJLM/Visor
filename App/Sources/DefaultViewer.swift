import AppKit
import UniformTypeIdentifiers

/// Makes Visor the app that opens images.
///
/// macOS asks the user to confirm every change of default app, so this runs
/// inside the normal app (never unattended) and asks for as few changes as
/// possible: first the generic image type, then, only if macOS still sends a
/// common format elsewhere, that format. Each request waits for the answer
/// before the next one, so confirmations appear one at a time.
@MainActor
enum DefaultViewer {
    /// Formats people actually open, most common first.
    static let commonTypes: [String] = [
        "public.jpeg", "public.heic", "public.png", "public.heif", "com.compuserve.gif", "org.webmproject.webp",
        "public.tiff", "public.avif", "com.microsoft.bmp", "public.jpeg-xl", "com.adobe.raw-image",
    ]

    private static let askedKey = "AskedToBecomeDefault"

    static func isDefault(for identifier: String) -> Bool {
        guard let type = UTType(identifier),
              let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static var missingTypes: [String] {
        commonTypes.filter { ImageDecoder.decodableTypes.contains($0) && !isDefault(for: $0) }
    }

    /// On first launch, offers once to become the default viewer.
    static func offerOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: askedKey), !missingTypes.isEmpty else { return }
        defaults.set(true, forKey: askedKey)
        let alert = NSAlert()
        alert.messageText = "Open your images with Visor?"
        alert.informativeText = "Visor can become the default app for JPEG, HEIC, PNG and other image files. macOS will ask you to confirm."
        alert.addButton(withTitle: "Use Visor")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await makeDefault(quitWhenDone: false) }
        }
    }

    /// Asks macOS to make Visor the default for images, waiting for each
    /// confirmation. With `quitWhenDone` (the install script), Visor quits
    /// afterwards.
    static func makeDefault(quitWhenDone: Bool) async {
        UserDefaults.standard.set(true, forKey: askedKey)
        NSApp.activate()
        let app = Bundle.main.bundleURL
        // One confirmation may cover every image type.
        if !missingTypes.isEmpty {
            await request(app: app, identifier: "public.image", until: { missingTypes.isEmpty || isDefault(for: "public.image") })
        }
        for identifier in missingTypes {
            await request(app: app, identifier: identifier, until: { isDefault(for: identifier) })
        }
        let done = commonTypes.count - missingTypes.count
        let alert = NSAlert()
        alert.messageText = missingTypes.isEmpty ? "Visor now opens your images." : "Visor opens \(done) of \(commonTypes.count) common image types."
        alert.informativeText = missingTypes.isEmpty ? "" : "You can change any of the others in Finder: Get Info › Open with › Change All."
        alert.runModal()
        if quitWhenDone { NSApp.terminate(nil) }
    }

    /// Sends one change request and waits (up to two minutes) for the user to
    /// answer the system confirmation.
    private static func request(app: URL, identifier: String, until applied: @escaping () -> Bool) async {
        guard let type = UTType(identifier) else { return }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
        } catch {
            return
        }
        let deadline = Date().addingTimeInterval(120)
        while !applied() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }
}
