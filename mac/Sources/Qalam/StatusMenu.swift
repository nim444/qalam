import AppKit
import ApplicationServices
import QalamCore
import ServiceManagement

/// The menu-bar icon and its menu. The menu is rebuilt each time it opens, so it always shows
/// the live state. The icon shows the mode and dims while no phone is connected.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let app: Controller

    init(app: Controller) {
        self.app = app
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    func refresh() {
        guard let button = item.button else { return }
        let name = app.mode == .ink ? "scribble.variable" : "pencil.tip"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Qalam")
            ?? NSImage(systemSymbolName: "pencil", accessibilityDescription: "Qalam")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = app.link == nil
        button.toolTip = app.link.map { "Qalam: \($0.name), \(String(format: "%.1f", $0.rttMs)) ms" } ?? "Qalam: waiting for the phone"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = app.settings

        menu.addItem(label(app.link.map { "● Phone connected · \($0.name) · \(String(format: "%.1f", $0.rttMs)) ms" }
            ?? "○ Waiting for the phone… (Bonjour: \(app.macName))"))
        menu.addItem(.separator())

        menu.addItem(action("Cursor mode", checked: app.mode == .cursor) { self.app.setMode(.cursor) })
        menu.addItem(action("Ink mode", key: "i", checked: app.mode == .ink) { self.app.setMode(.ink) })
        menu.addItem(.separator())

        for tool in Tool.allCases {
            let key = tool == .laser ? "l" : ""
            menu.addItem(action(tool.title, key: key, checked: s.tool == tool, indent: 1) { self.app.apply(.tool(tool.rawValue)) })
        }
        menu.addItem(submenu("Colour", Palette.colors.enumerated().map { i, c in
            let it = action(c.name, checked: s.color == i) { self.app.apply(.color(UInt8(i))) }
            it.image = swatch(i)
            return it
        }, indent: 1))
        menu.addItem(submenu("Size", Palette.sizes.enumerated().map { i, size in
            action(size.name, checked: s.size == i) { self.app.apply(.size(UInt8(i))) }
        }, indent: 1))
        menu.addItem(action("Undo", key: "z", enabled: app.board.canUndo, indent: 1) { self.app.apply(.undo) })
        menu.addItem(action("Clear", key: "c", enabled: !app.board.isEmpty, indent: 1) { self.app.apply(.clear) })
        let fades: [(String, Double)] = [("Never", 0), ("After 3 seconds", 3), ("After 5 seconds", 5), ("After 10 seconds", 10)]
        menu.addItem(submenu("Fade ink away", fades.map { title, secs in
            action(title, checked: s.fadeAfter == secs) { s.fadeAfter = secs }
        }, indent: 1))
        menu.addItem(.separator())

        var displays = app.target.ids.enumerated().map { i, id in
            let b = CGDisplayBounds(id)
            return action("\(displayName(id))  (\(Int(b.width))×\(Int(b.height)))", checked: app.target.index == i) {
                self.app.selectDisplay(i)
            }
        }
        displays.append(action("All displays", checked: app.target.index == app.target.count) {
            self.app.selectDisplay(self.app.target.count)
        })
        displays.append(.separator())
        displays.append(action("Next display", key: "d") { self.app.nextDisplay() })
        displays.append(action("Follow the mouse", checked: s.follow) { s.follow.toggle() })
        menu.addItem(submenu("Display: \(app.target.name)", displays))
        menu.addItem(action("Smooth the pen", checked: s.smoothing) { self.app.setSmoothing(!s.smoothing) })
        menu.addItem(.separator())

        if AXIsProcessTrusted() {
            menu.addItem(label("Accessibility: allowed"))
        } else {
            menu.addItem(action("Allow Accessibility (needed for Cursor mode)…") {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            })
        }
        let usb = !app.adbAvailable ? "USB fallback: adb not found"
            : app.usbReady.isEmpty ? "USB fallback: plug in the phone (USB debugging on)"
            : "USB fallback: ready"
        menu.addItem(label(usb))
        let login = SMAppService.mainApp
        menu.addItem(action("Open at login", checked: login.status == .enabled) {
            do {
                if login.status == .enabled { try login.unregister() } else { try login.register() }
            } catch {
                NSSound.beep()
            }
        })
        menu.addItem(.separator())
        menu.addItem(action("Qalam on GitHub") {
            NSWorkspace.shared.open(URL(string: "https://github.com/nim444/qalam")!)
        })
        menu.addItem(action("Quit Qalam", key: "q", modifiers: .command) { NSApp.terminate(nil) })
    }

    // MARK: Item helpers

    private func label(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    /// A menu item that runs `handler`. Keys are shown with ⌃⌥, the global hotkeys (Hotkeys.swift).
    private func action(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.control, .option],
                        checked: Bool = false, enabled: Bool = true, indent: Int = 0,
                        _ handler: @escaping () -> Void) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        it.keyEquivalentModifierMask = modifiers
        it.target = self
        it.representedObject = Handler(handler)
        it.state = checked ? .on : .off
        it.isEnabled = enabled
        it.indentationLevel = indent
        return it
    }

    private func submenu(_ title: String, _ items: [NSMenuItem], indent: Int = 0) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        items.forEach { sub.addItem($0) }
        it.submenu = sub
        it.indentationLevel = indent
        return it
    }

    private func swatch(_ index: Int) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(cgColor: Palette.cgColor(index))?.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.gray.withAlphaComponent(0.6).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }

    @objc private func fire(_ sender: NSMenuItem) {
        (sender.representedObject as? Handler)?.run()
        refresh()
    }
}

private final class Handler {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
