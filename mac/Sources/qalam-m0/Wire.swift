import CoreGraphics

/// Wire format v0, as used by the M0 feel test (unencrypted). Spec: docs/protocol.md.
enum Wire {
    static let port: UInt16 = 47474
    static let serviceType = "_qalam._udp"
    static let headerSize = 8 // "QL" | version | type | counter u32
    static let sampleSize = 16
}

enum FrameType: UInt8 {
    case pen = 1, ping = 2, pong = 3, display = 4
}

struct PenSample {
    var tUs: UInt32       // phone clock, µs since the pad opened
    var x: Double         // 0...1 across the pad
    var y: Double
    var pressure: Double  // 0...1
    var tiltX: Double     // degrees
    var tiltY: Double
    var flags: UInt8

    var inRange: Bool { flags & 0x01 != 0 }
    var touching: Bool { flags & 0x02 != 0 }
    var button: Bool { flags & 0x04 != 0 }
    var eraser: Bool { flags & 0x08 != 0 }
}

enum Frame {
    case pen(counter: UInt32, samples: [PenSample])
    case ping(counter: UInt32, tNs: Int64, lastRttUs: UInt32)
    case nextDisplay(counter: UInt32)

    var counter: UInt32 {
        switch self {
        case .pen(let c, _), .ping(let c, _, _), .nextDisplay(let c): return c
        }
    }

    static func parse(_ bytes: [UInt8]) -> Frame? {
        guard bytes.count >= Wire.headerSize, bytes[0] == 0x51, bytes[1] == 0x4C, bytes[2] == 0 else {
            return nil
        }
        var r = LE(bytes, at: 3)
        let type = r.u8()
        let counter = r.u32()
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
            return .pen(counter: counter, samples: samples)
        case .ping:
            guard r.remaining >= 12 else { return nil }
            let t = r.i64()
            return .ping(counter: counter, tNs: t, lastRttUs: r.u32())
        case .display:
            guard r.remaining >= 1, r.u8() == 1 else { return nil } // 1 = next display
            return .nextDisplay(counter: counter)
        default:
            return nil
        }
    }
}

/// Pong: echoes the ping's timestamp and describes the target: its size in points (the pad takes
/// the same shape), its place in the display cycle, and its name.
func makePong(counter: UInt32, tNs: Int64, display: DisplayTarget) -> [UInt8] {
    var name = Array(display.name.utf8.prefix(64))
    while !name.isEmpty, String(validating: name, as: UTF8.self) == nil { name.removeLast() } // whole characters only
    var b: [UInt8] = [0x51, 0x4C, 0, FrameType.pong.rawValue]
    b.reserveCapacity(Wire.headerSize + 15 + name.count)
    putLE(&b, UInt64(counter), bytes: 4)
    putLE(&b, UInt64(bitPattern: tNs), bytes: 8)
    let size = display.bounds.size
    putLE(&b, UInt64(UInt16(clamping: Int(size.width))), bytes: 2)
    putLE(&b, UInt64(UInt16(clamping: Int(size.height))), bytes: 2)
    b.append(UInt8(clamping: display.index))
    b.append(UInt8(clamping: display.count))
    b.append(UInt8(name.count))
    b.append(contentsOf: name)
    return b
}

private func putLE(_ b: inout [UInt8], _ v: UInt64, bytes: Int) {
    for k in 0..<bytes { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(k)))) }
}

/// Little-endian reader over a byte array. Callers check `remaining` first.
private struct LE {
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
