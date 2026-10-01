import AppKit

// The ink overlay: strokes live in global coordinates (points, top-left origin of the main
// display, the space CGEvent and CGDisplayBounds use), and one transparent panel per screen draws
// the part that falls on it. Panels ignore the mouse, so the real mouse keeps working underneath,
// and they are ordinary windows, so screen recordings capture the ink.

/// One pen or highlighter stroke.
final class Stroke {
    let tool: Tool
    let color: CGColor
    let base: CGFloat // the size setting, in points
    private(set) var points: [CGPoint] = []
    private(set) var widths: [CGFloat] = []
    private(set) var bounds = CGRect.null
    private var pressure: Double?

    init(tool: Tool, color: CGColor, base: CGFloat) {
        self.tool = tool
        self.color = color
        self.base = base
    }

    var highlighterWidth: CGFloat { base * 4 }

    /// Adds a point; returns the area that needs redrawing.
    func add(_ p: CGPoint, pressure raw: Double) -> CGRect {
        let pr = pressure.map { $0 * 0.6 + raw * 0.4 } ?? raw // calm the width down a little
        pressure = pr
        let w = tool == .highlighter ? highlighterWidth : base * CGFloat(0.35 + 0.95 * min(max(pr, 0), 1))
        points.append(p)
        widths.append(w)
        // The curve through the last points can move a little when a new one arrives.
        var dirty = CGRect.null
        for q in points.suffix(3) { dirty = dirty.union(CGRect(x: q.x - w, y: q.y - w, width: 2 * w, height: 2 * w)) }
        bounds = bounds.union(dirty)
        return dirty
    }

    /// Whether an eraser of `radius` at `p` touches this stroke.
    func hit(_ p: CGPoint, radius: CGFloat) -> Bool {
        let reach = radius + (tool == .highlighter ? highlighterWidth : base * 1.3) / 2
        guard bounds.insetBy(dx: -radius, dy: -radius).contains(p), let first = points.first else { return false }
        if points.count == 1 { return hypot(first.x - p.x, first.y - p.y) <= reach }
        for i in 1..<points.count where distance(p, points[i - 1], points[i]) <= reach { return true }
        return false
    }

    func draw(in ctx: CGContext, clip: CGRect) {
        guard !points.isEmpty, bounds.intersects(clip) else { return }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(color)
        if tool == .highlighter {
            // One path inside a transparency layer, so the stroke never darkens where it overlaps itself.
            ctx.saveGState()
            ctx.setAlpha(0.38)
            ctx.beginTransparencyLayer(in: bounds.intersection(clip), auxiliaryInfo: nil)
            ctx.setLineWidth(highlighterWidth)
            ctx.addPath(smoothPath())
            ctx.strokePath()
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            return
        }
        if points.count == 1 {
            let w = widths[0]
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: points[0].x - w / 2, y: points[0].y - w / 2, width: w, height: w))
            return
        }
        // Quadratic pieces between midpoints, each with its own width; round caps hide the joins.
        let n = points.count
        for i in 0..<n {
            let a = i == 0 ? points[0] : mid(points[i - 1], points[i])
            let b = i == n - 1 ? points[i] : mid(points[i], points[i + 1])
            let c = points[i], w = widths[i]
            let minX = min(a.x, b.x, c.x), minY = min(a.y, b.y, c.y)
            let box = CGRect(x: minX - w, y: minY - w,
                             width: max(a.x, b.x, c.x) - minX + 2 * w, height: max(a.y, b.y, c.y) - minY + 2 * w)
            guard box.intersects(clip) else { continue }
            ctx.setLineWidth(w)
            ctx.move(to: a)
            ctx.addQuadCurve(to: b, control: points[i])
            ctx.strokePath()
        }
    }

    private func smoothPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        for i in 1..<max(points.count, 1) {
            if i == points.count - 1 { path.addLine(to: points[i]) } else { path.addQuadCurve(to: mid(points[i], points[i + 1]), control: points[i]) }
        }
        if points.count == 1 { path.addLine(to: points[0]) }
        return path
    }
}

/// The laser pointer's trail: points fade out and disappear after `life` seconds.
final class LaserTrail {
    static let life: TimeInterval = 0.75
    private(set) var points: [(p: CGPoint, t: TimeInterval)] = []

    var isEmpty: Bool { points.isEmpty }
    var bounds: CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(x: $1.p.x - 16, y: $1.p.y - 16, width: 32, height: 32)) }
    }

    func add(_ p: CGPoint, now: TimeInterval) { points.append((p, now)) }

    func prune(now: TimeInterval) {
        if let i = points.firstIndex(where: { now - $0.t < Self.life }) { points.removeFirst(i) } else { points.removeAll() }
    }

    func draw(in ctx: CGContext, now: TimeInterval) {
        guard points.count > 1 else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setShadow(offset: .zero, blur: 10, color: Palette.laser)
        for i in 1..<points.count {
            let f = 1 - (now - points[i].t) / Self.life
            guard f > 0 else { continue }
            ctx.setStrokeColor(Palette.laser.copy(alpha: CGFloat(f)) ?? Palette.laser)
            ctx.setLineWidth(2 + 5 * CGFloat(f))
            ctx.move(to: points[i - 1].p)
            ctx.addLine(to: points[i].p)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

/// What the overlay shows while the pen hovers in Ink mode.
struct Hover {
    var point: CGPoint
    var tool: Tool
    var color: CGColor
    var radius: CGFloat

    var rect: CGRect { CGRect(x: point.x - radius - 14, y: point.y - radius - 14, width: 2 * radius + 28, height: 2 * radius + 28) }
}

/// All the ink, its undo history, and the overlay panels that show it.
final class InkBoard {
    private enum Action {
        case add(Stroke)
        case erase([Stroke])
        case clear([Stroke])
    }

    private(set) var strokes: [Stroke] = []
    private var history: [Action] = []
    private var active: Stroke?
    private var erased: [Stroke]?
    private var eraserRadius: CGFloat = 15
    private var tool: Tool?
    private let laser = LaserTrail()
    private var laserTimer: Timer?
    private var hover: Hover?
    private var overlays: [Overlay] = []
    private var shown = false
    private var fading = false
    private(set) var lastActivity = ProcessInfo.processInfo.systemUptime

    /// Ink mode is on: keep the overlay up even while it's empty (for the hover ring).
    var wantsVisible = false {
        didSet { updateVisibility() }
    }

    var isEmpty: Bool { strokes.isEmpty && active == nil }
    var canUndo: Bool { !history.isEmpty }
    var historyDepth: Int { history.count }

    init() {
        rebuildOverlays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.rebuildOverlays() }
    }

    // MARK: Pen

    func begin(at p: CGPoint, pressure: Double, tool: Tool, color: Int, size: Int) {
        lastActivity = ProcessInfo.processInfo.systemUptime
        self.tool = tool
        switch tool {
        case .pen, .highlighter:
            let s = Stroke(tool: tool, color: Palette.cgColor(color), base: Palette.points(size))
            active = s
            invalidate(s.add(p, pressure: pressure))
        case .eraser:
            erased = []
            eraserRadius = Palette.points(size) * 3
            erase(at: p)
        case .laser:
            laser.add(p, now: lastActivity)
            startLaserTimer()
        }
        updateVisibility()
    }

    func extend(to p: CGPoint, pressure: Double) {
        lastActivity = ProcessInfo.processInfo.systemUptime
        switch tool {
        case .pen?, .highlighter?:
            if let active { invalidate(active.add(p, pressure: pressure)) }
        case .eraser?:
            erase(at: p)
        case .laser?:
            laser.add(p, now: lastActivity)
        case nil:
            break
        }
    }

    func end() {
        if let s = active {
            strokes.append(s)
            history.append(.add(s))
            active = nil
        }
        if let e = erased, !e.isEmpty { history.append(.erase(e)) }
        erased = nil
        tool = nil
        updateVisibility()
    }

    func setHover(_ h: Hover?) {
        if let old = hover { invalidate(old.rect) }
        hover = h
        if let h { invalidate(h.rect) }
    }

    // MARK: Editing

    func undo() {
        guard let last = history.popLast() else { return }
        switch last {
        case .add(let s):
            strokes.removeAll { $0 === s }
            invalidate(s.bounds)
        case .erase(let list), .clear(let list):
            strokes.append(contentsOf: list)
            list.forEach { invalidate($0.bounds) }
        }
        updateVisibility()
    }

    func clear() {
        end()
        guard !strokes.isEmpty else { return }
        history.append(.clear(strokes))
        strokes.forEach { invalidate($0.bounds) }
        strokes.removeAll()
        updateVisibility()
    }

    /// Fades the overlay out, then clears (undo brings the ink back).
    func fadeOutAndClear() {
        guard !strokes.isEmpty, !fading else { return }
        fading = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.6
            overlays.forEach { $0.panel.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.clear()
            self.overlays.forEach { $0.panel.alphaValue = 1 }
            self.fading = false
        })
    }

    private func erase(at p: CGPoint) {
        let hit = strokes.filter { $0.hit(p, radius: eraserRadius) }
        guard !hit.isEmpty else { return }
        strokes.removeAll { s in hit.contains { $0 === s } }
        erased?.append(contentsOf: hit)
        hit.forEach { invalidate($0.bounds) }
    }

    // MARK: Laser

    private func startLaserTimer() {
        guard laserTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.laserTick() }
        RunLoop.main.add(t, forMode: .common)
        laserTimer = t
    }

    private func laserTick() {
        let before = laser.bounds
        laser.prune(now: ProcessInfo.processInfo.systemUptime)
        invalidate(before.union(laser.bounds))
        if laser.isEmpty {
            laserTimer?.invalidate()
            laserTimer = nil
            updateVisibility()
        }
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, clip: CGRect) {
        for s in strokes { s.draw(in: ctx, clip: clip) }
        active?.draw(in: ctx, clip: clip)
        if !laser.isEmpty { laser.draw(in: ctx, now: ProcessInfo.processInfo.systemUptime) }
        if let hover, hover.rect.intersects(clip) { drawHover(hover, in: ctx) }
    }

    private func drawHover(_ h: Hover, in ctx: CGContext) {
        let p = h.point
        ctx.saveGState()
        if h.tool == .laser {
            ctx.setShadow(offset: .zero, blur: 12, color: Palette.laser)
            ctx.setFillColor(Palette.laser)
            ctx.fillEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
        } else {
            // A ring in the ink colour with a faint dark edge, so it shows on any background.
            let r = h.radius
            let ring = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.setLineWidth(3)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
            ctx.strokeEllipse(in: ring)
            ctx.setLineWidth(1.5)
            ctx.setStrokeColor(h.tool == .eraser ? CGColor(gray: 1, alpha: 0.9) : h.color)
            ctx.strokeEllipse(in: ring)
        }
        ctx.restoreGState()
    }

    func invalidate(_ rect: CGRect) {
        guard !rect.isNull else { return }
        for o in overlays where o.bounds.intersects(rect) {
            o.view.setNeedsDisplay(rect.offsetBy(dx: -o.bounds.minX, dy: -o.bounds.minY))
        }
    }

    private func updateVisibility() {
        let show = wantsVisible || !strokes.isEmpty || active != nil || !laser.isEmpty
        guard show != shown else { return }
        shown = show
        for o in overlays { if show { o.panel.orderFrontRegardless() } else { o.panel.orderOut(nil) } }
    }

    private func rebuildOverlays() {
        overlays.forEach { $0.panel.orderOut(nil) }
        overlays = NSScreen.screens.compactMap { Overlay(screen: $0, board: self) }
        shown = false
        updateVisibility()
    }
}

/// A transparent, click-through panel covering one screen.
final class Overlay {
    let panel: NSPanel
    let view: InkView
    let bounds: CGRect // the screen in global coordinates

    init?(screen: NSScreen, board: InkBoard) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value else { return nil }
        bounds = CGDisplayBounds(id)
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.setFrame(screen.frame, display: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        view = InkView(frame: NSRect(origin: .zero, size: screen.frame.size), origin: bounds.origin, board: board)
        panel.contentView = view
    }
}

final class InkView: NSView {
    private let origin: CGPoint
    private weak var board: InkBoard?

    init(frame: NSRect, origin: CGPoint, board: InkBoard) {
        self.origin = origin
        self.board = board
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true } // top-left origin, like global coordinates
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let board else { return }
        ctx.translateBy(x: -origin.x, y: -origin.y)
        board.draw(in: ctx, clip: dirtyRect.offsetBy(dx: origin.x, dy: origin.y))
    }
}

private func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) : 0
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}
