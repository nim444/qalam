import AppKit
import ApplicationServices
import Foundation
import SystemConfiguration

// qalam-m0: the M0 feel-test receiver. The phone pad sends pen frames over Wi-Fi (UDP, found via
// Bonjour) or, as a fallback, over USB (TCP through adb reverse); this moves the Mac cursor and
// prints link numbers every 2 s.

struct Options {
    var display: Int? = 0 // nil = all displays
    var follow = true
    var dryRun = false
    var smooth = true
    var slop = 3.0
    var adb = true
    var listDisplays = false
}

func usage() -> Never {
    print("""
    usage: qalam-m0 [--display N|all] [--no-follow] [--raw] [--slop POINTS] [--dry-run] [--no-adb] [--list-displays]

      --display N      start on display N (see --list-displays; default 0 = main display)
      --display all    start with the pad spanning all displays
      --no-follow      don't switch to the display the real mouse is moved to
      --raw            no smoothing (default: one-euro filter on)
      --slop POINTS    how far a tap may wobble before it becomes a drag (default 3)
      --dry-run        receive and print numbers, but don't touch the cursor
      --no-adb         don't set up the USB fallback (adb reverse)
    """)
    exit(0)
}

func number(_ s: String?) -> Double {
    guard let s, let v = Double(s) else { usage() }
    return v
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--display":
            let v = it.next()
            o.display = v == "all" ? nil : Int(number(v))
        case "--no-follow": o.follow = false
        case "--slop": o.slop = number(it.next())
        case "--raw": o.smooth = false
        case "--dry-run": o.dryRun = true
        case "--no-adb": o.adb = false
        case "--list-displays": o.listDisplays = true
        default: usage()
        }
    }
    return o
}

/// IPv4 addresses of the interfaces that are up, for typing into the phone if Bonjour fails.
func lanAddresses() -> [String] {
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
    defer { freeifaddrs(ifap) }
    var out: [String] = []
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = p.pointee
        guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
              ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0
        else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let name = String(cString: ifa.ifa_name)
        out.append("\(ip) (\(name))")
    }
    return out
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

// MARK: - Start

setvbuf(stdout, nil, _IOLBF, 0) // line-buffered even when piped to a file
let opts = parseOptions()
let displays = activeDisplays()

if opts.listDisplays {
    for (i, id) in displays.enumerated() {
        let b = CGDisplayBounds(id)
        print("\(i): \(displayName(id))  \(Int(b.width))×\(Int(b.height)) pt\(i == 0 ? "  (main)" : "")")
    }
    exit(0)
}

let target = DisplayTarget(index: opts.display)
let macName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"

print("Qalam M0: feel-test receiver")
print("Display:   \(target.name)  \(Int(target.bounds.width))×\(Int(target.bounds.height)) pt, \(target.count) display(s), follow the mouse \(opts.follow ? "on" : "off")")
print("Listening: UDP + TCP \(Wire.port), Bonjour \(Wire.serviceType) as \"\(macName)\"")
print("Mac IPs:   \(lanAddresses().joined(separator: ", "))")
print("Options:   smoothing \(opts.smooth ? "on" : "off"), tap slop \(opts.slop) pt\(opts.dryRun ? ", DRY RUN (cursor untouched)" : "")")

if !opts.dryRun {
    let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    if !trusted {
        print("""
        ⚠ No Accessibility permission, so macOS will silently drop the cursor events.
          System Settings → Privacy & Security → Accessibility → enable the terminal app you run
          this from, then start qalam-m0 again.
        """)
    }
}

let queue = DispatchQueue(label: "qalam.rx", qos: .userInteractive)
let injector = Injector(display: target.bounds, dryRun: opts.dryRun, slop: opts.slop, smooth: opts.smooth)
let stats: [Link: LinkStats] = [.wifi: LinkStats(), .usb: LinkStats()]
var penLink: Link?
var goneReported: Set<Link> = []
var pongCounter: UInt32 = 0

let receiver = Receiver(queue: queue) { frame, link, reply in
    let now = DispatchTime.now().uptimeNanoseconds
    let s = stats[link]!
    if s.lastSeen == 0 || goneReported.contains(link) {
        print("\(timestamp()) \(link.rawValue): phone connected")
        goneReported.remove(link)
    }
    s.seen(counter: frame.counter, now: now)

    switch frame {
    case .ping(_, let tNs, let rttUs):
        s.phoneRttUs = rttUs
        pongCounter &+= 1
        reply(makePong(counter: pongCounter, tNs: tNs, display: target))
    case .nextDisplay:
        target.next()
        injector.retarget(target.bounds)
        print("\(timestamp()) display → \(target.name) (\(Int(target.bounds.width))×\(Int(target.bounds.height)) pt)")
    case .pen(_, let samples):
        s.pen(samples: samples.count, now: now)
        if penLink != link {
            print("\(timestamp()) pen frames now arrive on \(link.rawValue)")
            penLink = link
        }
        for sample in samples { injector.apply(sample) }
    }
}

do {
    try receiver.start(serviceName: macName)
} catch {
    print("Can't listen on port \(Wire.port): \(error)")
    exit(1)
}

let adb = AdbReverse()
if opts.adb { adb.start() }

// Watchdog: never leave a mouse button held down because the link died mid-stroke.
let watchdog = DispatchSource.makeTimerSource(queue: queue)
watchdog.schedule(deadline: .now() + 0.25, repeating: 0.25)
watchdog.setEventHandler {
    let now = DispatchTime.now().uptimeNanoseconds
    if injector.holding, let l = penLink, now - stats[l]!.lastSeen > 1_000_000_000 {
        injector.release()
        print("\(timestamp()) \(l.rawValue) went quiet mid-stroke: released the mouse button")
    }
    // Follow the mouse: if the real mouse moved the cursor onto another display while the pen
    // was away, the pad goes there too. (Our own events keep the cursor on the target display.)
    let penAway = ProcessInfo.processInfo.systemUptime - injector.lastActive > 0.5
    if opts.follow, let cursor = CGEvent(source: nil)?.location, target.follow(cursor, allowed: penAway) {
        injector.retarget(target.bounds)
        print("\(timestamp()) followed the mouse → \(target.name)")
    }
    for (link, s) in stats where s.lastSeen != 0 && !goneReported.contains(link) && now - s.lastSeen > 3_000_000_000 {
        goneReported.insert(link)
        print("\(timestamp()) \(link.rawValue): phone gone")
    }
}
watchdog.resume()

let reporter = DispatchSource.makeTimerSource(queue: queue)
reporter.schedule(deadline: .now() + 2, repeating: 2)
reporter.setEventHandler {
    for link in [Link.wifi, .usb] {
        if let line = stats[link]!.line(link, seconds: 2) { print("\(timestamp()) \(line)  [\(injector.state)]") }
    }
}
reporter.resume()

dispatchMain()
