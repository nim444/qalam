import Carbon.HIToolbox

/// Global ⌃⌥ hotkeys (Carbon's RegisterEventHotKey: no Accessibility or Input Monitoring needed).
final class Hotkeys {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    /// `keyCode` is a kVK_* virtual key code.
    func add(_ keyCode: Int, _ handler: @escaping () -> Void) {
        installHandler()
        let id = UInt32(handlers.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: 0x514C_4D20 /* "QLM " */, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return } // taken by another app: skip it
        refs.append(ref)
        handlers[id] = handler
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if let userData {
                let me = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
                me.handlers[hk.id]?()
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }
}
