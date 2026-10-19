import AppKit
import QalamCore
import ScreenCaptureKit

/// Captures the pad's area for the phone's snapshot. Qalam's own windows are left out: the ink
/// overlay would double the strokes, since the phone draws its own copy of the ink on top. The
/// pointer is left out too; the phone shows where the pen is.
enum ScreenGrab {
    /// The macOS prompt is shown once per launch; after that the phone just gets the status.
    private static var asked = false

    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording. Returns false when it isn't granted (yet); macOS shows its
    /// prompt only the first time, so the caller can open System Settings.
    @discardableResult
    static func request() -> Bool {
        asked = true
        return CGRequestScreenCaptureAccess()
    }

    /// `displays` covering `area` (global points, top-left origin): one display, or all of them
    /// composited into their union. Calls `done` on any queue.
    static func capture(displays: [CGDirectDisplayID], area: CGRect, fitting: CGSize,
                        done: @escaping (CGImage?, SnapshotStatus) -> Void) {
        guard allowed else {
            if !asked { request() }
            done(nil, .noPermission)
            return
        }
        let backing = displays.map { id -> CGFloat in
            guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
            return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        }.max() ?? 1
        let size = Snapshot.fit(points: area.size, backing: backing, max: fitting)
        guard size.width > 0 else { return done(nil, .captureFailed) }
        let scale = size.width / area.width
        let me = getpid()

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let own = content.applications.filter { $0.processID == me }
                var parts: [(CGRect, CGImage)] = []
                for id in displays {
                    guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                    let bounds = CGDisplayBounds(id)
                    let config = SCStreamConfiguration()
                    // ScreenCaptureKit scales on the GPU, so the full-size frame never exists here.
                    config.width = max(1, Int((bounds.width * scale).rounded()))
                    config.height = max(1, Int((bounds.height * scale).rounded()))
                    config.showsCursor = false
                    let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                    parts.append((bounds, try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)))
                }
                if parts.count == 1, displays.count == 1 { return done(parts[0].1, .ok) }
                done(composite(parts, area: area, size: size, scale: scale), parts.isEmpty ? .captureFailed : .ok)
            } catch {
                done(nil, allowed ? .captureFailed : .noPermission)
            }
        }
    }

    /// The displays drawn where they sit in the arrangement; gaps between them stay black.
    private static func composite(_ parts: [(CGRect, CGImage)], area: CGRect, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        for (bounds, image) in parts {
            // Global coordinates have y going down; the bitmap's y goes up.
            let rect = CGRect(x: (bounds.minX - area.minX) * scale, y: CGFloat(h) - (bounds.maxY - area.minY) * scale,
                              width: bounds.width * scale, height: bounds.height * scale)
            ctx.draw(image, in: rect)
        }
        return ctx.makeImage()
    }
}
