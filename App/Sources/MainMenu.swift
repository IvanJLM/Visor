import AppKit

/// The menu bar, built in code (no nib to load at launch).
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, title: "Visor")
        app.addItem(item("About Visor", #selector(AppDelegate.showAbout(_:))))
        app.addItem(.separator())
        app.addItem(item("Hide Visor", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit Visor", #selector(NSApplication.terminate(_:)), "q"))

        let file = submenu(in: main, title: "File")
        file.addItem(item("Open…", #selector(AppDelegate.showOpenPanel(_:)), "o"))
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(.separator())
        file.addItem(item("Show in Finder", #selector(ImageWindowController.showInFinder(_:)), "r", [.command, .shift]))
        file.addItem(item("Open in Preview", #selector(ImageWindowController.openInPreview(_:)), "p", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Move to Trash", #selector(ImageWindowController.moveToTrash(_:)), "\u{8}"))

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(item("Copy", #selector(ImageWindowController.copy(_:)), "c"))

        let view = submenu(in: main, title: "View")
        view.addItem(item("Actual Size", #selector(ImageWindowController.actualSize(_:)), "0"))
        view.addItem(item("Zoom to Fit", #selector(ImageWindowController.zoomToFit(_:)), "9"))
        view.addItem(item("Zoom In", #selector(ImageWindowController.zoomIn(_:)), "+"))
        view.addItem(item("Zoom Out", #selector(ImageWindowController.zoomOut(_:)), "-"))
        view.addItem(.separator())
        view.addItem(item("Rotate Left", #selector(ImageWindowController.rotateLeft(_:)), "l"))
        view.addItem(item("Rotate Right", #selector(ImageWindowController.rotateRight(_:)), "r"))
        view.addItem(item("Flip Horizontal", #selector(ImageWindowController.flipHorizontal(_:))))
        view.addItem(item("Flip Vertical", #selector(ImageWindowController.flipVertical(_:))))
        view.addItem(.separator())
        view.addItem(item("Previous Image", #selector(ImageWindowController.previousImage(_:)), arrow(NSLeftArrowFunctionKey), []))
        view.addItem(item("Next Image", #selector(ImageWindowController.nextImage(_:)), arrow(NSRightArrowFunctionKey), []))
        view.addItem(item("First Image", #selector(ImageWindowController.firstImage(_:)), arrow(NSUpArrowFunctionKey)))
        view.addItem(item("Last Image", #selector(ImageWindowController.lastImage(_:)), arrow(NSDownArrowFunctionKey)))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let window = submenu(in: main, title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt16(key))!))
    }
}
