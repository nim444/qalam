import AppKit
import Carbon.HIToolbox
import QalamCore

// Qalam: the Mac side. A menu-bar app (no Dock icon) that receives the S Pen from the phone and
// either drives the cursor or writes on a transparent overlay.

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let app = Controller()
    private var menu: StatusMenu?
    private let hotkeys = Hotkeys()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try app.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Qalam can't listen on port \(Wire.port)"
            alert.informativeText = "Another copy of Qalam (or qalam-m0) is probably running. Quit it and open Qalam again.\n\n\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let menu = StatusMenu(app: app)
        self.menu = menu
        app.onChange = { [weak menu] in menu?.refresh() }

        hotkeys.add(kVK_ANSI_I) { [app] in app.setMode(app.mode == .ink ? .cursor : .ink) }
        hotkeys.add(kVK_ANSI_C) { [app] in app.apply(.clear) }
        hotkeys.add(kVK_ANSI_Z) { [app] in app.apply(.undo) }
        hotkeys.add(kVK_ANSI_D) { [app] in app.nextDisplay() }
        hotkeys.add(kVK_ANSI_L) { [app] in
            app.apply(.tool(app.settings.tool == .laser ? Tool.pen.rawValue : Tool.laser.rawValue))
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
