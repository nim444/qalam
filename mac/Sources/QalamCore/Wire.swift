import CoreGraphics
import Foundation

/// Wire format v1: a 24-byte header, then the payload sealed with AES-256-GCM (Secure.swift);
/// pairing messages travel in the clear (Pairing.swift). Spec: docs/protocol.md.
public enum Wire {
    /// 47474. `QALAM_PORT` overrides it for a second, test instance, which then skips Bonjour so
    /// phones never find it.
    public static let port: UInt16 = testPort ?? 47474
    public static let testPort = ProcessInfo.processInfo.environment["QALAM_PORT"].flatMap { UInt16($0) }
    public static let serviceType = "_qalam._udp"
    public static let version: UInt8 = 1
    public static let headerSize = 24 // "QL" | version | type | pairing u32 | session u64 | counter u64
    public static let sampleSize = 16
}

public enum FrameType: UInt8 {
    case pen = 1, ping = 2, pong = 3, display = 4, control = 5
    case pairHello = 6, pairCommit = 7, pairNonce = 8, pairReveal = 9

    public var isPairing: Bool { rawValue >= 6 }
}

/// The 24-byte frame header: in the clear, but authenticated (it's the AEAD's associated data).
public struct Header {
    public var type: UInt8
    public var pairing: UInt32
    public var session: UInt64
    public var counter: UInt64

    public init(type: UInt8, pairing: UInt32 = 0, session: UInt64 = 0, counter: UInt64 = 0) {
        self.type = type
        self.pairing = pairing
        self.session = session
        self.counter = counter
    }

    public var bytes: [UInt8] {
        var b: [UInt8] = [0x51, 0x4C, Wire.version, type]
        putLE(&b, UInt64(pairing), bytes: 4)
        putLE(&b, session, bytes: 8)
        putLE(&b, counter, bytes: 8)
        return b
    }

    /// nil for anything that isn't a v1 frame (including v0 frames from an old phone app).
    public static func parse(_ b: [UInt8]) -> Header? {
        guard b.count >= Wire.headerSize, b[0] == 0x51, b[1] == 0x4C, b[2] == Wire.version else { return nil }
        var r = LE(b, at: 3)
        let type = r.u8()
        let pairing = r.u32()
        let session = r.read(8)
        return Header(type: type, pairing: pairing, session: session, counter: r.read(8))
    }
}

public struct PenSample {
    public var tUs: UInt32       // phone clock, µs since the pad opened
    public var x: Double         // 0...1 across the pad
    public var y: Double
    public var pressure: Double  // 0...1
    public var tiltX: Double     // degrees
    public var tiltY: Double
    public var flags: UInt8

    public var inRange: Bool { flags & 0x01 != 0 }
    public var touching: Bool { flags & 0x02 != 0 }
    public var button: Bool { flags & 0x04 != 0 }
    public var eraser: Bool { flags & 0x08 != 0 }
}

/// Where a sample lands in `rect` (global coordinates, points, top-left origin).
public func padPoint(_ s: PenSample, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + min(s.x * rect.width, rect.width - 1),
            y: rect.minY + min(s.y * rect.height, rect.height - 1))
}

/// A command from the phone strip (frame type 5). See docs/protocol.md.
public enum Control {
    case mode(UInt8)  // 0 cursor, 1 ink
    case tool(UInt8)  // 0 pen, 1 highlighter, 2 laser, 3 eraser
    case color(UInt8) // index into the shared palette
    case size(UInt8)  // 0 small, 1 medium, 2 large
    case undo
    case clear
}

/// What the Mac tells the phone in every pong, so the strip shows the Mac's real state.
public struct PadState {
    public var mode: UInt8 = 0
    public var tool: UInt8 = 0
    public var color: UInt8 = 0
    public var size: UInt8 = 1
    /// The ink on the Mac: strokes showing and undo steps. The phone's copy of the ink follows
    /// these, so an undo or clear done on the Mac (menu, hotkey, fade) shows on the phone too.
    public var inkStrokes: UInt16 = 0
    public var inkHistory: UInt16 = 0
    public init() {}
}

/// A decrypted frame from the phone.
public enum Frame {
    case pen([PenSample])
    case ping(tNs: Int64, lastRttUs: UInt32)
    case nextDisplay
    case control(Control)

    public static func parse(type: UInt8, payload: [UInt8]) -> Frame? {
        var r = LE(payload, at: 0)
        switch FrameType(rawValue: type) {
        case .pen:
            guard r.remaining >= 1 else { return nil }
            let n = Int(r.u8())
            guard r.remaining >= n * Wire.sampleSize else { return nil }
            var samples: [PenSample] = []
            samples.reserveCapacity(n)
            for _ in 0..<n {
                let t = r.u32(), x = r.u16(), y = r.u16(), p = r.u16()
                let tx = r.i16(), ty = r.i16(), f = r.u8()
                _ = r.u8()
                samples.append(PenSample(
                    tUs: t, x: Double(x) / 65535, y: Double(y) / 65535, pressure: Double(p) / 65535,
                    tiltX: Double(tx) / 100, tiltY: Double(ty) / 100, flags: f))
            }
            return .pen(samples)
        case .ping:
            guard r.remaining >= 12 else { return nil }
            let t = r.i64()
            return .ping(tNs: t, lastRttUs: r.u32())
        case .display:
            guard r.remaining >= 1, r.u8() == 1 else { return nil } // 1 = next display
            return .nextDisplay
        case .control:
            guard r.remaining >= 2 else { return nil }
            let cmd = r.u8(), value = r.u8()
            switch cmd {
            case 1: return .control(.mode(value))
            case 2: return .control(.tool(value))
            case 3: return .control(.color(value))
            case 4: return .control(.size(value))
            case 5: return .control(.undo)
            case 6: return .control(.clear)
            default: return nil
            }
        default:
            return nil
        }
    }
}

/// Pong payload: echoes the ping's timestamp and describes the target: its size in points (the
/// pad takes the same shape), its place in the display cycle and its name, then the strip state.
public func pongPayload(tNs: Int64, display: DisplayTarget, state: PadState) -> [UInt8] {
    let name = utf8Prefix(display.name, 64)
    var b: [UInt8] = []
    b.reserveCapacity(19 + name.count)
    putLE(&b, UInt64(bitPattern: tNs), bytes: 8)
    let size = display.bounds.size
    putLE(&b, UInt64(UInt16(clamping: Int(size.width))), bytes: 2)
    putLE(&b, UInt64(UInt16(clamping: Int(size.height))), bytes: 2)
    b.append(UInt8(clamping: display.index))
    b.append(UInt8(clamping: display.count))
    b.append(UInt8(name.count))
    b.append(contentsOf: name)
    b.append(contentsOf: [state.mode, state.tool, state.color, state.size])
    putLE(&b, UInt64(state.inkStrokes), bytes: 2)
    putLE(&b, UInt64(state.inkHistory), bytes: 2)
    return b
}

/// The first bytes of `s` as UTF-8, at most `max`, cut at a character boundary.
func utf8Prefix(_ s: String, _ max: Int) -> [UInt8] {
    var b = Array(s.utf8.prefix(max))
    while !b.isEmpty, String(validating: b, as: UTF8.self) == nil { b.removeLast() }
    return b
}

func putLE(_ b: inout [UInt8], _ v: UInt64, bytes: Int) {
    for k in 0..<bytes { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(k)))) }
}

/// Little-endian reader over a byte array. Callers check `remaining` first.
struct LE {
    let b: [UInt8]
    var i: Int

    init(_ b: [UInt8], at i: Int) { self.b = b; self.i = i }

    var remaining: Int { b.count - i }

    mutating func read(_ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<n { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
        i += n
        return v
    }
    mutating func u8() -> UInt8 { UInt8(read(1)) }
    mutating func u16() -> UInt16 { UInt16(read(2)) }
    mutating func i16() -> Int16 { Int16(bitPattern: u16()) }
    mutating func u32() -> UInt32 { UInt32(read(4)) }
    mutating func i64() -> Int64 { Int64(bitPattern: read(8)) }
}
