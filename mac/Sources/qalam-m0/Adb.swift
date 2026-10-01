import Foundation

/// Keeps `adb reverse tcp:47474 tcp:47474` in place on every attached Android device, so the
/// phone reaches this Mac at its own 127.0.0.1 through the USB cable. That is the fallback the
/// phone uses when Wi-Fi stops answering. Checked every 3 s, so plugging the cable in later works.
final class AdbReverse {
    private let adb: String?
    private let queue = DispatchQueue(label: "qalam.adb", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var armed: Set<String> = []

    init() {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/usr/local/bin/adb",
        ]
        adb = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        guard adb != nil else {
            print("USB fallback off: adb not found")
            return
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 3)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        var serials: [String] = []
        for line in run(["devices"]).split(separator: "\n").dropFirst() { // after "List of devices attached"
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if cols.count >= 2 && cols[1] == "device" { serials.append(String(cols[0])) }
        }

        let rule = "tcp:\(Wire.port)"
        for serial in serials where !armed.contains(serial) {
            if !run(["-s", serial, "reverse", "--list"]).contains(rule) {
                _ = run(["-s", serial, "reverse", rule, rule])
            }
            if run(["-s", serial, "reverse", "--list"]).contains(rule) {
                armed.insert(serial)
                print("USB fallback ready on \(serial) (adb reverse \(rule))")
            }
        }
        for serial in armed.subtracting(serials) {
            armed.remove(serial)
            print("USB fallback: \(serial) disconnected")
        }
    }

    private func run(_ args: [String]) -> String {
        guard let adb else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
