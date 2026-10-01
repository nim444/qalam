import AppKit
import QalamCore

/// "Pair a phone": while it's open the Mac answers pairing requests. It waits for the phone,
/// then shows the 6-digit code; you click Pair only if the phone shows the same one.
final class PairingWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let heading = NSTextField(labelWithString: "")
    private let info = NSTextField(wrappingLabelWithString: "")
    private let code = NSTextField(labelWithString: "")
    private let pairButton = NSButton(title: "Pair", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let stack = NSStackView()
    private let responder: PairingResponder
    private let onClose: () -> Void
    private let autoAccept: Bool
    private var timeout: Timer?

    /// `autoAccept` is for automated tests only (see Controller.start).
    init(responder: PairingResponder, autoAccept: Bool = false, onClose: @escaping () -> Void) {
        self.responder = responder
        self.autoAccept = autoAccept
        self.onClose = onClose
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        panel.title = "Pair a phone"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.alignment = .center
        info.alignment = .center
        info.textColor = .secondaryLabelColor
        info.preferredMaxLayoutWidth = 340
        code.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        code.alignment = .center
        pairButton.target = self
        pairButton.action = #selector(pair)
        pairButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancelButton, pairButton])
        buttons.spacing = 12
        buttons.setHuggingPriority(.required, for: .horizontal) // stay compact, so the row is centred
        [heading, code, info, buttons].forEach { stack.addArrangedSubview($0) }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        panel.contentView = stack

        responder.onChange = { [weak self] in self?.update() }
        update()
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        armTimeout()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func update() {
        render(responder.current)
        // Fit the window to what's showing now (the code and the Pair button come and go).
        stack.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 400, height: stack.fittingSize.height))
    }

    private func render(_ attempt: PairingResponder.Attempt?) {
        guard let a = attempt else {
            heading.stringValue = "Pair a phone"
            info.stringValue = "On your phone, open Qalam and tap Pair. Keep this window open until both show the same code."
            code.isHidden = true
            pairButton.isHidden = true
            return
        }
        armTimeout()
        code.stringValue = a.code.map { "\($0.prefix(3)) \($0.suffix(3))" } ?? ""
        switch a.status {
        case .waiting:
            if autoAccept {
                DispatchQueue.main.async { [weak self] in self?.responder.accept() }
            }
            heading.stringValue = "“\(a.phoneName)” wants to pair"
            info.stringValue = "Click Pair only if your phone shows this same code."
            code.isHidden = false
            pairButton.isHidden = false
        case .accepted:
            heading.stringValue = "Paired with “\(a.phoneName)”"
            info.stringValue = "Every pen stroke between them is now encrypted."
            code.isHidden = true
            pairButton.isHidden = true
            cancelButton.title = "Done"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.panel.close() }
        case .refused:
            heading.stringValue = "Not paired"
            info.stringValue = "To try again, tap Pair on the phone."
            code.isHidden = true
            pairButton.isHidden = true
        }
    }

    /// Pairing stays open for 5 minutes after the last activity.
    private func armTimeout() {
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in self?.panel.close() }
    }

    @objc private func pair() {
        responder.accept()
    }

    @objc private func cancel() {
        responder.refuse()
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        timeout?.invalidate()
        responder.onChange = nil
        onClose()
    }
}
