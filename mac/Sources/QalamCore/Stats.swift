import Foundation

/// Numbers for one link, printed every 2 s while the pen is moving.
public final class LinkStats {
    public private(set) var lastSeen: UInt64 = 0 // uptime ns of the last frame of any kind
    public var phoneRttUs: UInt32 = 0            // round trip as measured by the phone's pings

    private var lastCounter: UInt64?
    private var frames = 0
    private var samples = 0
    private var lost = 0
    private var lastPen: UInt64?
    private var gapsMs: [Double] = []

    public init() {}

    public func seen(counter: UInt64, now: UInt64) {
        // The phone numbers every frame per link; a jump means frames were lost on the way.
        // A smaller number means the app restarted (or a late, reordered packet): just resync.
        if let last = lastCounter, counter > last { lost += Int(counter - last - 1) }
        lastCounter = counter
        lastSeen = now
    }

    public func pen(samples n: Int, now: UInt64) {
        frames += 1
        samples += n
        if let last = lastPen {
            let gap = Double(now - last) / 1_000_000
            if gap < 200 { gapsMs.append(gap) } // longer gaps are the pen resting, not jitter
        }
        lastPen = now
    }

    /// One line for the last interval, or nil when no pen frames arrived. Resets the counters.
    public func line(_ link: Link, seconds: Double) -> String? {
        defer {
            frames = 0
            samples = 0
            lost = 0
            gapsMs.removeAll(keepingCapacity: true)
        }
        guard frames > 0 else { return nil }
        let g = gapsMs.sorted()
        func pct(_ q: Double) -> Double { g.isEmpty ? 0 : g[min(g.count - 1, Int(Double(g.count) * q))] }
        let name = link.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
        return String(
            format: "%@ %4.0f frames/s %4.0f samples/s  lost %-3d gap p50 %4.1f p95 %4.1f max %5.1f ms  rtt %5.1f ms",
            name, Double(frames) / seconds, Double(samples) / seconds, lost,
            pct(0.5), pct(0.95), g.last ?? 0, Double(phoneRttUs) / 1000)
    }
}
