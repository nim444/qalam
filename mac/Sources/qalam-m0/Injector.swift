import AppKit
import CoreGraphics

/// Turns pen samples into Mac mouse events: hover moves the cursor, the tip is the left button,
/// the side button (pressed while hovering) is the right button. This is M0's Cursor mode; real
/// tablet events with pressure come in M4.
final class Injector {
    private let display: CGRect // target display in global coordinates (points, top-left origin)
    private let dryRun: Bool
    private let slop: Double    // points the tip may wander after touching before it counts as a drag
    private var smoother: Smoother?
    private let source = CGEventSource(stateID: .hidSystemState)

    private var touching = false
    private var dragging = false
    private var rightDown = false
    private var downPoint = CGPoint.zero
    private var clickState: Int64 = 0
    private var lastDownTime: TimeInterval = 0
    private var lastDownPoint = CGPoint(x: -100, y: -100)
    private var lastPosted = CGPoint(x: -1, y: -1)

    private(set) var state = "away"
    var holding: Bool { touching || rightDown }

    init(display: CGRect, dryRun: Bool, slop: Double, smooth: Bool) {
        self.display = display
        self.dryRun = dryRun
        self.slop = slop
        self.smoother = smooth ? Smoother() : nil
    }

    func apply(_ s: PenSample) {
        var p = CGPoint(
            x: display.minX + min(s.x * display.width, display.width - 1),
            y: display.minY + min(s.y * display.height, display.height - 1))
        if let smoother { p = smoother.filter(p, tUs: s.tUs) }

        guard s.inRange || s.touching else {
            release()
            smoother?.reset() // the pen comes back somewhere else; don't glide there
            state = "away"
            return
        }

        if s.touching && !touching {
            touching = true
            dragging = false
            downPoint = p
            let now = ProcessInfo.processInfo.systemUptime
            let near = hypot(p.x - lastDownPoint.x, p.y - lastDownPoint.y) < 6
            clickState = (now - lastDownTime < NSEvent.doubleClickInterval && near) ? clickState + 1 : 1
            lastDownTime = now
            lastDownPoint = p
            post(.leftMouseDown, at: p, button: .left)
        } else if !s.touching && touching {
            touching = false
            post(.leftMouseUp, at: dragging ? p : downPoint, button: .left)
        } else if touching {
            // A tap wobbles a little at ~2.7x scale; hold the cursor still until it clearly moves.
            if !dragging && hypot(p.x - downPoint.x, p.y - downPoint.y) > slop { dragging = true }
            if dragging { post(.leftMouseDragged, at: p, button: .left) }
        } else if p != lastPosted {
            post(rightDown ? .rightMouseDragged : .mouseMoved, at: p, button: rightDown ? .right : .left)
        }

        if s.button && !rightDown && !touching {
            rightDown = true
            post(.rightMouseDown, at: p, button: .right)
        } else if !s.button && rightDown {
            rightDown = false
            post(.rightMouseUp, at: p, button: .right)
        }

        state = touching ? "touch" : (rightDown ? "hover+button" : "hover")
    }

    /// Let go of any held button, e.g. when the pen leaves or the link drops mid-drag.
    func release() {
        if touching {
            touching = false
            post(.leftMouseUp, at: lastPosted, button: .left)
        }
        if rightDown {
            rightDown = false
            post(.rightMouseUp, at: lastPosted, button: .right)
        }
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton) {
        lastPosted = p
        guard !dryRun,
              let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        if type != .mouseMoved {
            e.setIntegerValueField(.mouseEventClickState, value: button == .left ? clickState : 1)
        }
        e.post(tap: .cghidEventTap)
    }
}

/// One-euro filter (Casiez et al., 2012) on x and y: strong smoothing while the pen is slow,
/// which removes hover jitter, and almost none while it moves fast, so strokes don't lag.
final class Smoother {
    private var x = OneEuro()
    private var y = OneEuro()
    private var lastT: UInt32?

    func filter(_ p: CGPoint, tUs: UInt32) -> CGPoint {
        let dt = lastT.map { Double(tUs &- $0) / 1_000_000 } ?? 0
        lastT = tUs
        let step = (dt > 0 && dt < 0.5) ? dt : 1.0 / 240
        return CGPoint(x: x.filter(p.x, dt: step), y: y.filter(p.y, dt: step))
    }

    func reset() {
        x = OneEuro()
        y = OneEuro()
        lastT = nil
    }
}

private struct OneEuro {
    var minCutoff = 2.0 // Hz
    var beta = 0.02     // per point/s
    var dCutoff = 1.0   // Hz
    private var value: Double?
    private var speed = 0.0

    mutating func filter(_ v: Double, dt: Double) -> Double {
        guard let prev = value else {
            value = v
            return v
        }
        speed += alpha(dCutoff, dt) * ((v - prev) / dt - speed)
        let next = prev + alpha(minCutoff + beta * abs(speed), dt) * (v - prev)
        value = next
        return next
    }

    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
