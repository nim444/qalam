import AppKit
import CoreGraphics

/// Active displays, main display first.
public func activeDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    let main = CGMainDisplayID()
    return [main] + ids.prefix(Int(n)).filter { $0 != main }
}

public func displayName(_ id: CGDirectDisplayID) -> String {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
    return screen?.localizedName ?? "Display \(id)"
}

/// The part of the desktop the pad maps to: one display, or all of them as one surface.
/// The phone cycles it (display 1 → 2 → … → all → 1), and with follow on it jumps to whichever
/// display the real mouse was moved to.
public final class DisplayTarget {
    public private(set) var ids = activeDisplays()
    private var current: CGDirectDisplayID? // nil = all displays
    private var cursorDisplay: CGDirectDisplayID?

    public init(index: Int?) {
        if let index { current = ids[min(max(index, 0), ids.count - 1)] } else { current = nil }
        if let cursor = CGEvent(source: nil)?.location {
            cursorDisplay = ids.first { CGDisplayBounds($0).contains(cursor) }
        }
    }

    /// Global coordinates (points, top-left origin), as CGEvent uses them.
    public var bounds: CGRect {
        if let current { return CGDisplayBounds(current) }
        return ids.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }

    public var name: String { current.map(displayName) ?? "All displays" }
    /// Position in the cycle: 0..<count for one display, count for "all".
    public var index: Int { current.flatMap { ids.firstIndex(of: $0) } ?? ids.count }
    public var count: Int { ids.count }

    public func next() {
        refresh()
        guard ids.count > 1 else { return }
        let i = index + 1
        current = i < ids.count ? ids[i] : (i == ids.count ? nil : ids[0])
    }

    /// Call every few hundred ms with the cursor position. When the cursor has moved onto another
    /// display since the last call, and `allowed` (the pen is away, so the real mouse moved it),
    /// the target switches to that display. Returns true when it switched. Not in "all" mode.
    public func follow(_ cursor: CGPoint, allowed: Bool) -> Bool {
        refresh()
        let hit = ids.first { CGDisplayBounds($0).contains(cursor) }
        guard let hit, hit != cursorDisplay else { return false }
        cursorDisplay = hit
        guard allowed, current != nil, hit != current else { return false }
        current = hit
        return true
    }

    /// Selects entry `index` of the cycle (`count` = all displays).
    public func select(_ index: Int) {
        refresh()
        current = index < ids.count ? ids[max(index, 0)] : nil
    }

    /// Picks up displays plugged in or removed since the last look.
    private func refresh() {
        ids = activeDisplays()
        if let c = current, !ids.contains(c) { current = CGMainDisplayID() }
    }
}
