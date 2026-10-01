import CryptoKit
import Foundation

// Wire v1 security (docs/protocol.md): every frame from a paired phone is sealed with AES-256-GCM
// under a key derived per session and per direction from the pairing key; the header is the
// associated data and the counter is the nonce. Unknown, forged or replayed frames are dropped.

public enum Direction {
    case phoneToMac, macToPhone

    var info: String { self == .phoneToMac ? "qalam v1 phone to mac" : "qalam v1 mac to phone" }
}

public func sessionKey(_ pairingKey: SymmetricKey, session: UInt64, _ direction: Direction) -> SymmetricKey {
    var salt: [UInt8] = []
    putLE(&salt, session, bytes: 8)
    return HKDF<SHA256>.deriveKey(inputKeyMaterial: pairingKey, salt: salt, info: Data(direction.info.utf8), outputByteCount: 32)
}

private func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
    var n: [UInt8] = [0, 0, 0, 0]
    putLE(&n, counter, bytes: 8)
    return try! AES.GCM.Nonce(data: n) // 12 bytes, always valid
}

/// Header ‖ AES-256-GCM(payload) ‖ tag.
public func seal(_ header: Header, _ payload: [UInt8], key: SymmetricKey) -> [UInt8] {
    let h = header.bytes
    let box = try! AES.GCM.seal(payload, using: key, nonce: nonce(header.counter), authenticating: h)
    return h + Array(box.ciphertext) + Array(box.tag)
}

/// The payload of a sealed frame, or nil if it was forged or damaged.
public func open(_ header: Header, _ frame: [UInt8], key: SymmetricKey) -> [UInt8]? {
    guard frame.count >= Wire.headerSize + 16 else { return nil }
    let body = frame[Wire.headerSize...]
    guard let box = try? AES.GCM.SealedBox(nonce: nonce(header.counter), ciphertext: body.dropLast(16), tag: body.suffix(16)),
          let plain = try? AES.GCM.open(box, using: key, authenticating: frame[0..<Wire.headerSize])
    else { return nil }
    return Array(plain)
}

/// Accepts each counter once: the highest seen so far plus a 64-frame window below it, so UDP
/// reordering is fine. Call it only after a frame has decrypted.
public struct ReplayWindow {
    private var top: UInt64 = 0
    private var seen: UInt64 = 0 // bit i: counter top - i has been accepted

    public init() {}

    public mutating func accept(_ c: UInt64) -> Bool {
        guard c > 0 else { return false }
        if c > top {
            let shift = c - top
            seen = shift >= 64 ? 1 : (seen << shift) | 1
            top = c
            return true
        }
        let d = top - c
        guard d < 64, seen & (1 << d) == 0 else { return false }
        seen |= 1 << d
        return true
    }
}

/// Between the network and the app: opens frames from paired phones, hands pairing messages to
/// the pairing responder (only while pairing is open), and seals the replies.
public final class Gate {
    public typealias Send = ([UInt8]) -> Void
    /// Seals a reply of `type` on the frame's own session.
    public typealias Reply = (FrameType, [UInt8]) -> Void

    public let store: PairingStore
    /// Set while the Mac's "Pair a phone…" window is open; nil = pairing messages are ignored.
    public var pairing: PairingResponder?
    /// Gets each decrypted frame with its counter (for loss stats).
    public var onFrame: ((Frame, UInt64, Link, @escaping Reply) -> Void)?
    /// When something unpaired (an old v0 app, or an unknown pairing) last knocked.
    public private(set) var lastRejected: Date?

    private final class Channel {
        let rx: SymmetricKey
        let tx: SymmetricKey
        var window = ReplayWindow()
        var sent: UInt64 = 0
        var lastUsed = Date()

        init(key: SymmetricKey, session: UInt64) {
            rx = sessionKey(key, session: session, .phoneToMac)
            tx = sessionKey(key, session: session, .macToPhone)
        }
    }

    private struct ChannelID: Hashable {
        let pairing: UInt32
        let session: UInt64
    }

    private var channels: [ChannelID: Channel] = [:]

    public init(store: PairingStore) {
        self.store = store
    }

    public func handle(_ bytes: [UInt8], link: Link, send: @escaping Send) {
        guard let h = Header.parse(bytes) else {
            lastRejected = Date()
            return
        }
        if FrameType(rawValue: h.type)?.isPairing == true {
            if let pairing { pairing.handle(h.type, Array(bytes[Wire.headerSize...]), send: send) } else { lastRejected = Date() }
            return
        }
        guard let key = store.key(for: h.pairing) else {
            lastRejected = Date()
            return
        }
        let id = ChannelID(pairing: h.pairing, session: h.session)
        let known = channels[id]
        let ch = known ?? Channel(key: key, session: h.session)
        guard let payload = open(h, bytes, key: ch.rx), ch.window.accept(h.counter),
              let frame = Frame.parse(type: h.type, payload: payload)
        else { return }
        if known == nil { // remember a session only once a frame of it has decrypted
            prune()
            channels[id] = ch
        }
        ch.lastUsed = Date()
        onFrame?(frame, h.counter, link) { type, reply in
            ch.sent += 1
            send(seal(Header(type: type.rawValue, pairing: h.pairing, session: h.session, counter: ch.sent), reply, key: ch.tx))
        }
    }

    /// Forgets the sessions of a phone that was just unpaired.
    public func drop(pairing: UInt32) {
        channels = channels.filter { $0.key.pairing != pairing }
    }

    private func prune() {
        guard channels.count > 32 else { return }
        let cutoff = Date().addingTimeInterval(-600)
        channels = channels.filter { $0.value.lastUsed > cutoff }
    }
}
