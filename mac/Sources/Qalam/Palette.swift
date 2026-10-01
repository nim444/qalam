import AppKit

/// What the pen does: drive the cursor, or write on the overlay.
enum Mode: UInt8 {
    case cursor = 0, ink = 1
}

/// Ink tools. The raw values go over the wire, so the phone's strip uses the same numbers.
enum Tool: UInt8, CaseIterable {
    case pen = 0, highlighter = 1, laser = 2, eraser = 3

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .laser: return "Laser pointer"
        case .eraser: return "Eraser"
        }
    }
}

/// Colours and sizes shared with the phone by index (android/…/Palette.kt has the same lists).
enum Palette {
    static let colors: [(name: String, rgb: UInt32)] = [
        ("Red", 0xFF3B30), ("Yellow", 0xFFD60A), ("Green", 0x30D158),
        ("Blue", 0x0A84FF), ("Black", 0x1C1C1E), ("White", 0xFFFFFF),
    ]
    static let sizes: [(name: String, points: CGFloat)] = [("Small", 3), ("Medium", 5), ("Large", 9)]
    static let laser = CGColor(srgbRed: 1, green: 0.17, blue: 0.2, alpha: 1)

    static func cgColor(_ index: Int) -> CGColor {
        let rgb = colors[min(max(index, 0), colors.count - 1)].rgb
        return CGColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func points(_ size: Int) -> CGFloat { sizes[min(max(size, 0), sizes.count - 1)].points }
}

/// Choices kept between launches. The mode is not: Qalam always starts in Cursor mode.
final class Settings {
    private let d = UserDefaults.standard

    var tool: Tool {
        get { Tool(rawValue: UInt8(clamping: d.integer(forKey: "tool"))) ?? .pen }
        set { d.set(Int(newValue.rawValue), forKey: "tool") }
    }
    var color: Int {
        get { min(max(d.integer(forKey: "color"), 0), Palette.colors.count - 1) }
        set { d.set(newValue, forKey: "color") }
    }
    var size: Int {
        get { min(max(d.object(forKey: "size") as? Int ?? 1, 0), Palette.sizes.count - 1) }
        set { d.set(newValue, forKey: "size") }
    }
    /// Seconds after the last stroke before the ink fades away; 0 = never.
    var fadeAfter: Double {
        get { d.double(forKey: "fadeAfter") }
        set { d.set(newValue, forKey: "fadeAfter") }
    }
    var follow: Bool {
        get { d.object(forKey: "follow") as? Bool ?? true }
        set { d.set(newValue, forKey: "follow") }
    }
    var smoothing: Bool {
        get { d.object(forKey: "smoothing") as? Bool ?? true }
        set { d.set(newValue, forKey: "smoothing") }
    }
}
