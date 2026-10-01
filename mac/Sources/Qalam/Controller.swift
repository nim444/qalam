import AppKit
import QalamCore
import SystemConfiguration

/// The app's brain: receives the phone's frames, routes pen samples to the cursor (Cursor mode)
/// or the ink overlay (Ink mode), applies the strip's commands, and answers pings with the state
/// the strip should show. Everything runs on the main queue.
final class Controller {
    let settings = Settings()
    let target = DisplayTarget(index: 0)
    let board = InkBoard()
    let macName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    private(set) var mode = Mode.cursor
    private(set) var usbReady: [String] = []
    var adbAvailable: Bool { adb.available }

    /// Called when anything the menu or the status icon shows has changed.
    var onChange: (() -> Void)?

    private lazy var injector = Injector(display: target.bounds, dryRun: false, slop: 3, smooth: settings.smoothing)
    private var receiver: Receiver?
    private let adb = AdbReverse()
    private let stats: [Link: LinkStats] = [.wifi: LinkStats(), .usb: LinkStats()]
    private var penLink: Link?
    private var connected = false
    private var pongCounter: UInt32 = 0
    private let inkSmoother = Smoother()
    private var inkTouching = false
    private var lastPenActive: TimeInterval = 0
    private var timer: Timer?

    func start() throws {
        let r = Receiver(queue: .main) { [weak self] frame, link, reply in self?.handle(frame, link, reply) }
        try r.start(serviceName: macName)
        receiver = r
        adb.verbose = false
        adb.onChange = { [weak self] serials in
            self?.usbReady = serials
            self?.onChange?()
        }
        if Wire.testPort == nil { adb.start() } // a test instance leaves the phone's adb alone
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: State for the menu

    /// The link the phone is using, with its round trip, or nil when no phone is connected.
    var link: (name: String, rttMs: Double)? {
        guard connected, let l = penLink ?? freshestLink() else { return nil }
        return (l.rawValue, Double(stats[l]!.phoneRttUs) / 1000)
    }

    var padState: PadState {
        var s = PadState()
        s.mode = mode.rawValue
        s.tool = settings.tool.rawValue
        s.color = UInt8(settings.color)
        s.size = UInt8(settings.size)
        s.inkStrokes = UInt16(clamping: board.strokes.count)
        s.inkHistory = UInt16(clamping: board.historyDepth)
        return s
    }

    // MARK: Commands (phone strip, menu, hotkeys)

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        injector.release()
        endInk()
        mode = m
        board.wantsVisible = m == .ink
        onChange?()
    }

    func apply(_ c: Control) {
        switch c {
        case .mode(let v): setMode(Mode(rawValue: v) ?? .cursor)
        case .tool(let v):
            settings.tool = Tool(rawValue: v) ?? .pen
            setMode(.ink) // picking a tool means you want to write
        case .color(let v):
            settings.color = Int(v)
            if settings.tool == .eraser || settings.tool == .laser { settings.tool = .pen }
            setMode(.ink)
        case .size(let v): settings.size = Int(v)
        case .undo: board.undo()
        case .clear: board.clear()
        }
        onChange?()
    }

    func nextDisplay() {
        target.next()
        retarget()
    }

    func selectDisplay(_ index: Int) {
        target.select(index)
        retarget()
    }

    func setSmoothing(_ on: Bool) {
        settings.smoothing = on
        injector.smoothing = on
        inkSmoother.reset()
        onChange?()
    }

    private func retarget() {
        injector.retarget(target.bounds)
        inkSmoother.reset()
        endInk()
        onChange?()
    }

    // MARK: Frames

    private func handle(_ frame: Frame, _ link: Link, _ reply: Receiver.Reply) {
        let s = stats[link]!
        s.seen(counter: frame.counter, now: DispatchTime.now().uptimeNanoseconds)
        if !connected {
            connected = true
            onChange?()
        }
        switch frame {
        case .ping(_, let tNs, let rttUs):
            s.phoneRttUs = rttUs
            pongCounter &+= 1
            reply(makePong(counter: pongCounter, tNs: tNs, display: target, state: padState))
        case .nextDisplay:
            nextDisplay()
        case .control(_, let c):
            apply(c)
        case .pen(_, let samples):
            if penLink != link {
                penLink = link
                onChange?()
            }
            for sample in samples { route(sample) }
        }
    }

    private func route(_ s: PenSample) {
        if s.inRange || s.touching { lastPenActive = ProcessInfo.processInfo.systemUptime }
        switch mode {
        case .cursor: injector.apply(s)
        case .ink: ink(s)
        }
    }

    private func ink(_ s: PenSample) {
        guard s.inRange || s.touching else {
            endInk()
            inkSmoother.reset()
            return
        }
        var p = padPoint(s, in: target.bounds)
        if settings.smoothing { p = inkSmoother.filter(p, tUs: s.tUs) }
        // Holding the side button turns any tool into the eraser.
        let tool: Tool = (s.button || s.eraser) ? .eraser : settings.tool

        if s.touching {
            if inkTouching {
                board.extend(to: p, pressure: s.pressure)
            } else {
                inkTouching = true
                board.setHover(nil)
                board.begin(at: p, pressure: s.pressure, tool: tool, color: settings.color, size: settings.size)
            }
        } else {
            if inkTouching {
                inkTouching = false
                board.end()
            }
            let base = Palette.points(settings.size)
            let radius: CGFloat
            switch tool {
            case .eraser: radius = base * 3
            case .highlighter: radius = base * 2
            default: radius = max(4, base * 0.8)
            }
            board.setHover(Hover(point: p, tool: tool, color: Palette.cgColor(settings.color), radius: radius))
        }
    }

    private func endInk() {
        if inkTouching {
            inkTouching = false
            board.end()
        }
        board.setHover(nil)
    }

    // MARK: Housekeeping, 4× a second

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let up = ProcessInfo.processInfo.systemUptime

        // The link died mid-stroke: let go of the mouse button and finish the stroke.
        if let l = penLink, now - stats[l]!.lastSeen > 1_000_000_000 {
            if injector.holding { injector.release() }
            endInk()
        }

        // Follow the mouse to another display (only while the pen is away; see DisplayTarget).
        if settings.follow, let cursor = CGEvent(source: nil)?.location,
           target.follow(cursor, allowed: up - lastPenActive > 0.5) {
            retarget()
        }

        if settings.fadeAfter > 0, !inkTouching, !board.isEmpty, up - board.lastActivity > settings.fadeAfter {
            board.fadeOutAndClear()
        }

        // Connected = some link heard from within the last 3 s.
        let alive = stats.values.contains { $0.lastSeen != 0 && now - $0.lastSeen < 3_000_000_000 }
        if alive != connected {
            connected = alive
            if !alive {
                penLink = nil
                injector.release()
                endInk()
            }
            onChange?()
        }
    }

    private func freshestLink() -> Link? {
        stats.max { $0.value.lastSeen < $1.value.lastSeen }?.key
    }
}
