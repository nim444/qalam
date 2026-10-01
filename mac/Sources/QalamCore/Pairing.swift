import CryptoKit
import Foundation

/// The Mac's id and its paired phones, kept in ~/Library/Application Support/Qalam/pairings.json
/// (mode 0600). `QALAM_STORE` overrides the path; a `QALAM_PORT` test instance uses a temporary
/// file, so tests never touch the real pairings.
public final class PairingStore {
    public struct Phone: Codable {
        public let id: UInt32
        public var name: String
        let key: Data
        public let added: Date
    }

    private struct Contents: Codable {
        var macId: String
        var phones: [Phone]
    }

    public private(set) var macId: [UInt8]
    public private(set) var phones: [Phone]
    private let url: URL

    public init() {
        url = Self.location()
        if let data = try? Data(contentsOf: url),
           let c = try? JSONDecoder().decode(Contents.self, from: data),
           let id = bytes(hex: c.macId), id.count == 8 {
            macId = id
            phones = c.phones
        } else {
            macId = randomBytes(8)
            phones = []
            save()
        }
    }

    public var macIdHex: String { hex(macId) }

    public func key(for id: UInt32) -> SymmetricKey? {
        phones.first { $0.id == id }.map { SymmetricKey(data: $0.key) }
    }

    /// Stores a new pairing. A phone pairing again under the same name replaces its old pairing,
    /// whose key that phone no longer has.
    public func add(name: String, key: SymmetricKey) -> UInt32 {
        phones.removeAll { $0.name == name }
        var id: UInt32
        repeat { id = UInt32.random(in: 1...UInt32.max) } while phones.contains { $0.id == id }
        phones.append(Phone(id: id, name: name, key: key.withUnsafeBytes { Data($0) }, added: Date()))
        save()
        return id
    }

    public func remove(_ id: UInt32) {
        phones.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(Contents(macId: hex(macId), phones: phones)) else { return }
        // Written to a file that is 0600 from the start, then moved over the old one.
        let tmp = dir.appendingPathComponent(".pairings-\(UUID().uuidString).json")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if fm.fileExists(atPath: url.path) {
            _ = try? fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try? fm.moveItem(at: tmp, to: url)
        }
    }

    private static func location() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["QALAM_STORE"] { return URL(fileURLWithPath: path) }
        if Wire.testPort != nil { return FileManager.default.temporaryDirectory.appendingPathComponent("qalam-test-pairings.json") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Qalam/pairings.json")
    }
}

/// The Mac's side of pairing (docs/protocol.md, "compare a 6-digit code"). It exists only while
/// the "Pair a phone…" window is open; nothing is stored until you click Pair.
public final class PairingResponder {
    public enum Status: UInt8 {
        case waiting = 0, accepted = 1, refused = 2
    }

    public final class Attempt {
        public let phoneName: String
        public fileprivate(set) var code: String?
        public fileprivate(set) var status = Status.waiting
        fileprivate let pp: [UInt8] // the phone's public key
        fileprivate let priv = Curve25519.KeyAgreement.PrivateKey()
        fileprivate let nm = randomBytes(16)
        fileprivate var np: [UInt8]?
        fileprivate var key: SymmetricKey?
        fileprivate var result: [UInt8] = []

        fileprivate init(pp: [UInt8], name: String) {
            self.pp = pp
            phoneName = name
        }

        fileprivate var pm: [UInt8] { Array(priv.publicKey.rawRepresentation) }
    }

    private let store: PairingStore
    private let macName: String
    private var attempts: [Attempt] = []

    /// The attempt the window shows: the latest one that has a code.
    public private(set) var current: Attempt?
    /// Called when a code appears or an attempt is decided.
    public var onChange: (() -> Void)?

    public init(store: PairingStore, macName: String) {
        self.store = store
        self.macName = macName
    }

    func handle(_ type: UInt8, _ body: [UInt8], send: Gate.Send) {
        switch FrameType(rawValue: type) {
        case .pairHello:
            guard body.count >= 33 else { return }
            let pp = Array(body[0..<32])
            let name = String(decoding: body[33..<min(body.count, 33 + Int(body[32]))], as: UTF8.self)
            let a = attempts.first { $0.pp == pp } ?? {
                let a = Attempt(pp: pp, name: name.isEmpty ? "Phone" : name)
                attempts.append(a)
                if attempts.count > 4 { attempts.removeFirst() }
                return a
            }()
            let mac = utf8Prefix(macName, 64)
            let commitment = sha256(Array("qalam commit v1".utf8), a.pm, a.pp, a.nm)
            send(Header(type: FrameType.pairCommit.rawValue).bytes + a.pm + commitment + store.macId + [UInt8(mac.count)] + mac)

        case .pairNonce:
            guard body.count >= 48, let a = attempts.first(where: { $0.pp == Array(body[0..<32]) }) else { return }
            let np = Array(body[32..<48])
            if a.np == nil {
                guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: a.pp),
                      let secret = try? a.priv.sharedSecretFromKeyAgreement(with: pub) else { return }
                a.np = np
                a.key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: np + a.nm,
                                                       sharedInfo: Data("qalam pairing v1".utf8), outputByteCount: 32)
                let h = sha256(Array("qalam code v1".utf8), a.pp, a.pm, np, a.nm)
                let n = (UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])) % 1_000_000
                a.code = String(format: "%06u", n)
                current = a
                onChange?()
            } else if a.np != np {
                return // a second nonce for the same key: not part of this exchange
            }
            var reply = Header(type: FrameType.pairReveal.rawValue).bytes + a.nm + [a.status.rawValue]
            if a.status == .accepted { reply += a.result }
            send(reply)

        default:
            return
        }
    }

    /// You clicked Pair: store the phone and let it know (on its next poll).
    public func accept() {
        guard let a = current, a.status == .waiting, let key = a.key else { return }
        let id = store.add(name: a.phoneName, key: key)
        var plain: [UInt8] = []
        putLE(&plain, UInt64(id), bytes: 4)
        plain += store.macId
        let zero = try! AES.GCM.Nonce(data: [UInt8](repeating: 0, count: 12))
        let box = try! AES.GCM.seal(plain, using: key, nonce: zero, authenticating: Array("qalam pair result v1".utf8))
        a.result = Array(box.ciphertext) + Array(box.tag)
        a.status = .accepted
        onChange?()
    }

    public func refuse() {
        guard let a = current, a.status == .waiting else { return }
        a.status = .refused
        onChange?()
    }
}

// MARK: Helpers

func sha256(_ parts: [UInt8]...) -> [UInt8] {
    var h = SHA256()
    for p in parts { h.update(data: p) }
    return Array(h.finalize())
}

func randomBytes(_ n: Int) -> [UInt8] {
    var g = SystemRandomNumberGenerator()
    return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

func bytes(hex s: String) -> [UInt8]? {
    guard s.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        guard let v = UInt8(s[i..<j], radix: 16) else { return nil }
        out.append(v)
        i = j
    }
    return out
}
