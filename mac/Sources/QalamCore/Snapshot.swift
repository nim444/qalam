import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Screen snapshot (docs/protocol.md, types 10–11): one still JPEG of the pad's area, sent only
// when the phone asks, split into chunks that each fit one UDP datagram.

/// A snapshot request from the phone (frame type 10).
public struct SnapshotRequest {
    public var request: UInt16
    /// The pad's size in pixels: the picture is scaled down to fit it, never up.
    public var maxW: UInt16
    public var maxH: UInt16
    /// Empty = the whole picture; otherwise only these chunks of picture `request` again.
    public var missing: [UInt16]
}

public enum SnapshotStatus: UInt8 {
    case ok = 0, noPermission = 1, captureFailed = 2, tooSoon = 3, unavailable = 4, gone = 5
}

public enum Snapshot {
    /// 1200 data bytes + 15 bytes of chunk header + 24 header + 16 tag = 1255 bytes per datagram,
    /// well under a 1500-byte MTU even over IPv6.
    public static let chunkData = 1200
    /// About 250 chunks: a picture arrives in well under a second on Wi-Fi.
    public static let targetBytes = 300_000
    /// Beyond this even a smaller, lower-quality picture is refused rather than sent.
    public static let hardLimitBytes = 1_000_000
    /// Enough to aim with on a phone pad, small enough to stay near `targetBytes`.
    public static let maxPixels = 2_000_000.0
    /// A new capture at most this often per phone.
    public static let minInterval: TimeInterval = 0.5

    /// One chunk payload. With a status other than ok, everything else is 0 and there's no data.
    public static func chunk(request: UInt16, status: SnapshotStatus, width: Int = 0, height: Int = 0,
                             jpeg: [UInt8] = [], index: Int = 0) -> [UInt8] {
        let ok = status == .ok
        let count = ok ? chunkCount(jpeg.count) : 0
        let lo = index * chunkData
        let data = ok ? jpeg[lo..<min(lo + chunkData, jpeg.count)] : []
        var b: [UInt8] = []
        b.reserveCapacity(15 + data.count)
        putLE(&b, UInt64(request), bytes: 2)
        b.append(status.rawValue)
        putLE(&b, UInt64(ok ? width : 0), bytes: 2)
        putLE(&b, UInt64(ok ? height : 0), bytes: 2)
        putLE(&b, UInt64(ok ? jpeg.count : 0), bytes: 4)
        putLE(&b, UInt64(ok ? index : 0), bytes: 2)
        putLE(&b, UInt64(count), bytes: 2)
        b.append(contentsOf: data)
        return b
    }

    public static func chunkCount(_ bytes: Int) -> Int { (bytes + chunkData - 1) / chunkData }

    /// The pixel size for an area of `points`, fitting `max` (the pad), never above the area's own
    /// pixels (`backing` = pixels per point), and capped at `maxPixels`.
    public static func fit(points: CGSize, backing: CGFloat, max: CGSize) -> CGSize {
        guard points.width > 0, points.height > 0, max.width > 0, max.height > 0 else { return .zero }
        var s = min(max.width / points.width, max.height / points.height, backing)
        let area = points.width * s * points.height * s
        if area > maxPixels { s *= (maxPixels / area).squareRoot() }
        return CGSize(width: Swift.max(1, (points.width * s).rounded(.down)),
                      height: Swift.max(1, (points.height * s).rounded(.down)))
    }

    /// JPEG bytes for `image`, stepping the quality and then the size down until it's near
    /// `targetBytes`. nil if it can't be encoded or stays above `hardLimitBytes`.
    public static func encode(_ image: CGImage) -> (jpeg: [UInt8], width: Int, height: Int)? {
        var img = image
        var quality = 0.65
        for _ in 0..<6 {
            guard let data = jpeg(img, quality: quality) else { return nil }
            if data.count <= targetBytes {
                return (data, img.width, img.height)
            }
            if quality > 0.45 {
                quality -= 0.15
            } else {
                guard let smaller = scaled(img, to: CGSize(width: Double(img.width) * 0.8, height: Double(img.height) * 0.8))
                else { return nil }
                img = smaller
            }
        }
        guard let data = jpeg(img, quality: quality), data.count <= hardLimitBytes else { return nil }
        return (data, img.width, img.height)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> [UInt8]? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](out as Data)
    }

    /// `image` redrawn at `size` (sRGB, no alpha: the JPEG has none anyway).
    public static func scaled(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// For the test hook: an image file, scaled to fit `max` and never up.
    public static func load(_ path: String, fitting max: CGSize) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let size = fit(points: CGSize(width: image.width, height: image.height), backing: 1, max: max)
        if Int(size.width) == image.width, Int(size.height) == image.height { return image }
        return scaled(image, to: size)
    }
}

/// Answers snapshot requests: one picture at a time per phone, captured at most every 0.5 s, kept
/// for resends, and sent as a paced burst. Main queue only (the Gate's replies aren't thread-safe).
public final class SnapshotServer {
    /// Captures the pad's area scaled to fit the given pixel size; calls back on any queue with an
    /// image, or the status to answer with.
    public typealias Capture = (_ fitting: CGSize, _ done: @escaping (CGImage?, SnapshotStatus) -> Void) -> Void

    private final class Phone {
        var lastCapture: TimeInterval = -.infinity
        var pending: UInt16?           // a capture in flight for this request
        var picture: Picture?          // the last answer, for resends
        var burst: DispatchSourceTimer?
        var lastUsed = Date()
    }

    private struct Picture {
        let request: UInt16
        let status: SnapshotStatus
        let width: Int
        let height: Int
        let jpeg: [UInt8]
    }

    private let capture: Capture
    private var phones: [UInt32: Phone] = [:] // by pairing, so a resend works after Wi-Fi ↔ USB
    private let encoder = DispatchQueue(label: "qalam.snapshot", qos: .userInitiated)

    /// Chunks per 2 ms tick: about 4 MB/s, so a 300 KB picture takes ~80 ms and the phone's
    /// socket buffer (a few hundred KB) never fills.
    private let perTick = 8

    public init(capture: @escaping Capture) {
        self.capture = capture
    }

    /// A clear answer for a Mac app that can't capture (qalam-m0).
    public static func refuse(_ req: SnapshotRequest, reply: Gate.Reply) {
        reply(.snapshotChunk, Snapshot.chunk(request: req.request, status: .unavailable))
    }

    public func handle(_ req: SnapshotRequest, from peer: Peer, reply: @escaping Gate.Reply) {
        let phone = phones[peer.pairing] ?? newPhone(peer.pairing)
        phone.lastUsed = Date()

        if !req.missing.isEmpty {
            guard let pic = phone.picture, pic.request == req.request else {
                send(Picture(request: req.request, status: .gone, width: 0, height: 0, jpeg: []), [0], to: phone, reply)
                return
            }
            let count = pic.status == .ok ? Snapshot.chunkCount(pic.jpeg.count) : 1
            send(pic, req.missing.map(Int.init).filter { $0 < count }, to: phone, reply)
            return
        }
        // The same request again: the burst (or the request) was lost, so send it all again.
        if let pic = phone.picture, pic.request == req.request {
            send(pic, nil, to: phone, reply)
            return
        }
        if phone.pending == req.request { return } // still capturing it

        let now = ProcessInfo.processInfo.systemUptime
        guard now - phone.lastCapture >= Snapshot.minInterval else {
            reply(.snapshotChunk, Snapshot.chunk(request: req.request, status: .tooSoon))
            return
        }
        phone.lastCapture = now
        phone.pending = req.request
        stop(phone)
        let fitting = CGSize(width: min(Int(req.maxW), 4096), height: min(Int(req.maxH), 4096))
        capture(fitting) { [weak self] image, status in
            // Encoding takes a few tens of ms: off the main queue, so the pen never waits.
            self?.encoder.async {
                var pic = Picture(request: req.request, status: status == .ok ? .captureFailed : status, width: 0, height: 0, jpeg: [])
                if status == .ok, let image, let enc = Snapshot.encode(image) {
                    pic = Picture(request: req.request, status: .ok, width: enc.width, height: enc.height, jpeg: enc.jpeg)
                }
                DispatchQueue.main.async {
                    guard let self, phone.pending == req.request else { return }
                    phone.pending = nil
                    phone.picture = pic
                    self.send(pic, nil, to: phone, reply)
                }
            }
        }
    }

    private func newPhone(_ pairing: UInt32) -> Phone {
        if phones.count > 8 { // forgotten or long-gone phones
            let cutoff = Date().addingTimeInterval(-600)
            phones = phones.filter { $0.value.lastUsed > cutoff }
        }
        let p = Phone()
        phones[pairing] = p
        return p
    }

    private func stop(_ phone: Phone) {
        phone.burst?.cancel()
        phone.burst = nil
    }

    /// Sends chunks `indices` (nil = all) of `pic`, a few per tick. Each chunk is sealed as it
    /// goes out, so the counters rise in sending order and the phone's replay window keeps up.
    private func send(_ pic: Picture, _ indices: [Int]?, to phone: Phone, _ reply: @escaping Gate.Reply) {
        stop(phone)
        guard pic.status == .ok else {
            reply(.snapshotChunk, Snapshot.chunk(request: pic.request, status: pic.status))
            return
        }
        var queue = indices ?? Array(0..<Snapshot.chunkCount(pic.jpeg.count))
        queue.reverse() // pop from the end, lowest index first
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        let perTick = self.perTick
        timer.setEventHandler { [weak timer] in
            for _ in 0..<perTick {
                guard let i = queue.popLast() else {
                    timer?.cancel() // releases this handler, and with it `phone`
                    if phone.burst === timer { phone.burst = nil }
                    return
                }
                reply(.snapshotChunk, Snapshot.chunk(request: pic.request, status: .ok, width: pic.width, height: pic.height,
                                                     jpeg: pic.jpeg, index: i))
            }
        }
        phone.burst = timer
        timer.resume()
    }
}
