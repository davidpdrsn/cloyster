import AppKit
import CloysterCore

/// The menu bar icon and everything in its menu.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let driver: Driver
    private var manager: Manager { driver.manager }
    private let isTrusted: () -> Bool

    init(driver: Driver, isTrusted: @escaping () -> Bool) {
        self.driver = driver
        self.isTrusted = isTrusted
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Cloyster")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !isTrusted() {
            menu.addItem(action("Grant Accessibility Access…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }

        let clusters = manager.controllers
        if clusters.isEmpty {
            menu.addItem(label("No clusters"))
        }
        for controller in clusters {
            let dissolve = action("Dissolve \(controller.name)", #selector(dissolve(_:)))
            dissolve.representedObject = controller
            menu.addItem(dissolve)
        }
        if clusters.count > 1 {
            menu.addItem(action("Dissolve All", #selector(dissolveAll)))
        }

        menu.addItem(.separator())
        menu.addItem(label("⌘-drag a window to another's edge to join"))
        menu.addItem(label("⌘-drag it away to leave"))
        menu.addItem(.separator())
        menu.addItem(action("Quit Cloyster", #selector(quit)))
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func dissolve(_ sender: NSMenuItem) {
        guard let controller = sender.representedObject as? Controller else { return }
        manager.dissolve(controller)
    }

    @objc private func dissolveAll() {
        manager.dissolveAll()
    }

    @objc private func openAccessibilitySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        URL(string: url).map { _ = NSWorkspace.shared.open($0) }
    }

    @objc private func quit() {
        driver.stop()
        NSApp.terminate(nil)
    }
}
