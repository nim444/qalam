# Research: prior art and findings (1 Oct 2026)

## Projects that already do part of this

| Project | What it does | Stack | License | What we take from it |
|---|---|---|---|---|
| [Weylus](https://github.com/H-M-H/Weylus) (9.6k ★) | Tablet → computer, through a **browser** page that mirrors the screen | Rust server, web client, H.264 | AGPL-style (don't copy code) | The best-known one. **On macOS it only moves the mouse:** no pressure, no tilt. Pressure only works on Linux (uinput). Mirroring costs 25–60 ms. |
| [PenBridge](https://github.com/Eta06/PenBridge) | **Galaxy Tab + S Pen → macOS** over USB: hover, pressure, tilt, button | Flutter on both sides | MIT | Closest match. Transport is `adb reverse` (a WebSocket over USB), 40-byte binary packets, 4 ms batching. On their roadmap: Android Open Accessory (USB without ADB) and a DriverKit virtual HID. Early prototype, primary display only. |
| [Penpal](https://github.com/Renoceros/Penpal.docs) | iPad + Apple Pencil → Mac tablet over USB | Swift | docs only | Claims under 3 ms by **not mirroring the screen**: "digitizer only". It injects `kCGEventTabletProximity` and sets both pressure fields. |
| [pencil-probe](https://github.com/ma-syu/pencil-probe) | Apple Pencil → macOS VM, tablet events through `CGEventPost` | Swift | MIT | **Reference code for injecting tablet events on macOS** (`Sources/IO/TabletInjector.swift`). See below. |
| [android-spen-hid-client](https://github.com/dotcomdomain/android-spen-hid-client) | S Pen → Windows as a real USB HID digitizer | Kotlin | GPL-3 (don't copy code) | Needs **root** (USB gadget mode). Windows only. |
| VirtualTablet, PenCast | S Pen → Mac/PC tablet over Wi-Fi/USB | closed, paid | — | Proof that the idea works and people pay for it |

**Mac overlay ("draw on screen") apps, for the Ink mode:**

| Project | Stack | License | Note |
|---|---|---|---|
| [spotdraw](https://github.com/asub927/spotdraw) | Swift, native, 450 KB | MIT | Draw, cursor highlight, spotlight, zoom; a Presentify alternative |
| [Scratchpad](https://github.com/Bisaam/Scratchpad) | Swift | MIT | Minimal: transparent overlay on every display, menu-bar icon only |
| [DrawPen](https://github.com/DmytroVasin/DrawPen) (1k ★) | Electron | MIT | Good list of tools to copy (laser, shapes, fade) |
| [sfpoint](https://github.com/daniel-carreon/sfpoint), [macdraw](https://github.com/aadityakumarsah/macdraw) | Swift | no license | Ideas only |

None of them combines the two parts we want: **phone S Pen as the input, plus a Mac ink overlay
for recording.** The overlay apps all draw with the Mac's own mouse.

## Findings that shape the design

1. **A Mac app is unavoidable.** macOS has no generic driver for HID *digitizers*. Android can act
   as a Bluetooth HID device (`BluetoothHidDevice`, Android 9+), but a pen descriptor does
   nothing on a Mac; only a relative mouse would work. We need a Mac process for the overlay
   anyway, so the phone sends raw pen data and the Mac app does the rest.
2. **Pressure on macOS works from user space.** Post tablet events with `CGEventPost`. This needs
   the **Accessibility** permission and no driver or DriverKit entitlement. The sequence, taken
   from pencil-probe:
   - proximity **enter**: a mouse event with subtype `tabletProximity` (2), *plus* a standalone
     `.tabletProximity` event
   - every move: a mouse event (`mouseMoved` / `leftMouseDown` / `leftMouseDragged` / `leftMouseUp`)
     with subtype `tabletPoint` (1), carrying `kCGTabletEventPointPressure`,
     `kCGMouseEventPressure` and tilt X/Y, *plus* a standalone `.tabletPointer` event, because
     apps such as Clip Studio only listen to that second path
   - proximity **leave** when the pen lifts away from the screen
   - set the subtype field *before* the other fields
3. **The S26 Ultra S Pen is still a passive EMR (Wacom-style) pen.** Samsung removed its Bluetooth
   (no Air Actions since the S25 Ultra), but the digitizer stays, so **hover, pressure, tilt
   and the side button all reach apps** as `MotionEvent` data (`TOOL_TYPE_STYLUS`,
   `ACTION_HOVER_*`, `AXIS_PRESSURE`, `AXIS_TILT`, `BUTTON_STYLUS_PRIMARY`). We don't need the
   pen's Bluetooth.
4. **Getting low latency on Android.**
   - `View.requestUnbufferedDispatch()` delivers every pen sample instead of one batch per frame.
   - Read the historical samples (`getHistoricalX/Y`); the digitizer samples faster than the
     display refreshes.
   - `androidx.input` `MotionEventPredictor` predicts the next point.
   - Jetpack Ink (`androidx.ink`, stable 1.0, Dec 2025) and `androidx.graphics` front-buffered
     rendering draw the local echo in about 4 ms.
   - These are AndroidX libraries, so the Android app is a normal Gradle project.
5. **Mirroring the screen is what makes the others slow.** Penpal is fast because it sends only
   pen data. We don't need a picture of the Mac on the phone: you look at the Mac, as with a
   screenless Wacom Intuos, and hovering shows where the pen will land.
6. **The phone is about the size of a small Wacom.** The S26 Ultra screen is about 159 × 73 mm in
   landscape; the active area of a Wacom Intuos S is 152 × 95 mm. To keep a 14" MacBook
   Pro's 1.54:1 shape, the pad uses about 112 × 73 mm (about 2.7× scale). That leaves a strip of about
   45 mm on the side for the toolbar.
7. **Transport options:**
   - **Wi-Fi:** UDP on the LAN, Bonjour for discovery. Typically 3–15 ms, with occasional spikes
     when the phone's Wi-Fi power saving kicks in. Fix:
     `WifiManager.createWifiLock(WIFI_MODE_FULL_LOW_LATENCY)`.
   - **USB with `adb reverse`:** what PenBridge does. Lowest jitter, but needs USB debugging.
   - **USB with Android Open Accessory:** the Mac acts as USB host and talks bulk transfers, with
     no developer mode. More work; later.
   - **Bluetooth:** rejected as the main channel, because of latency and because of finding 1.
8. **Ink in recordings.** A normal `NSWindow` above everything is captured by ScreenCaptureKit and
   QuickTime by default (`sharingType` stays `.readOnly`), so the ink is in the video with no
   extra work. The overlay sets `ignoresMouseEvents = true`, so the real mouse and trackpad keep
   working underneath while the pen draws.
