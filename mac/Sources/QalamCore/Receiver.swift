import Foundation
import Network

public enum Link: String {
    case wifi = "Wi-Fi"
    case usb = "USB"
}

/// Listens for the phone on two paths that carry the same frames:
/// - UDP (Wi-Fi), advertised over Bonjour as `_qalam._udp` so the phone finds the Mac by itself;
/// - TCP (USB), which the phone reaches at its own 127.0.0.1 through `adb reverse`. TCP frames
///   carry a u16 little-endian length prefix.
public final class Receiver {
    public typealias Reply = ([UInt8]) -> Void

    private let queue: DispatchQueue
    private let onFrame: (Frame, Link, @escaping Reply) -> Void
    private var listeners: [NWListener] = []

    public init(queue: DispatchQueue, onFrame: @escaping (Frame, Link, @escaping Reply) -> Void) {
        self.queue = queue
        self.onFrame = onFrame
    }

    public func start(serviceName: String) throws {
        let port = NWEndpoint.Port(rawValue: Wire.port)!

        let udp = try NWListener(using: .udp, on: port)
        if Wire.testPort == nil { udp.service = NWListener.Service(name: serviceName, type: Wire.serviceType) }
        udp.newConnectionHandler = { [weak self] c in self?.startUDP(c) }
        udp.stateUpdateHandler = { Receiver.report("UDP", $0) }
        udp.serviceRegistrationUpdateHandler = { change in
            if case .add(let endpoint) = change { print("Bonjour: advertising \(endpoint)") }
        }
        udp.start(queue: queue)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let tcp = try NWListener(using: NWParameters(tls: nil, tcp: tcpOptions), on: port)
        tcp.newConnectionHandler = { [weak self] c in self?.startTCP(c) }
        tcp.stateUpdateHandler = { Receiver.report("TCP", $0) }
        tcp.start(queue: queue)

        listeners = [udp, tcp]
    }

    private static func report(_ name: String, _ state: NWListener.State) {
        switch state {
        case .failed(let error): print("\(name) listener failed: \(error)")
        case .waiting(let error): print("\(name) listener waiting: \(error)")
        default: break
        }
    }

    // MARK: UDP (Wi-Fi)

    private func startUDP(_ c: NWConnection) {
        c.start(queue: queue)
        receiveUDP(c)
    }

    private func receiveUDP(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let frame = Frame.parse([UInt8](data)) {
                self.onFrame(frame, .wifi) { reply in
                    c.send(content: Data(reply), completion: .idempotent)
                }
            }
            if error == nil { self.receiveUDP(c) } else { c.cancel() }
        }
    }

    // MARK: TCP (USB through adb reverse)

    private func startTCP(_ c: NWConnection) {
        c.start(queue: queue)
        receiveTCP(c, buffer: [])
    }

    private func receiveTCP(_ c: NWConnection, buffer: [UInt8]) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(contentsOf: data) }

            let reply: Reply = { r in
                var framed = [UInt8(r.count & 0xFF), UInt8(r.count >> 8)]
                framed.append(contentsOf: r)
                c.send(content: Data(framed), completion: .idempotent)
            }
            var start = 0
            while buf.count - start >= 2 {
                let len = Int(buf[start]) | Int(buf[start + 1]) << 8
                guard buf.count - start - 2 >= len else { break }
                if let frame = Frame.parse(Array(buf[(start + 2)..<(start + 2 + len)])) {
                    self.onFrame(frame, .usb, reply)
                }
                start += 2 + len
            }
            buf.removeFirst(start)

            if isComplete || error != nil {
                c.cancel()
                return
            }
            self.receiveTCP(c, buffer: buf)
        }
    }
}
