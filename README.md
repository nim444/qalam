# Qalam

*Qalam* (قلم) is Persian for "pen".

Qalam turns a **Galaxy S26 Ultra and its S Pen** into a pen tablet for the Mac. There is no
tablet to buy: the phone is the drawing surface and the Mac is where you look.

- **Cursor:** hovering the pen moves the Mac cursor. Touching the screen with the tip is a click
  or a drag, and the side button is a right-click.
- **Ink:** the pen writes on a transparent layer above everything on the Mac screen. It shows up
  in screen recordings, so you can circle things, underline or sketch while you record.
- **Tablet (later):** real pressure and tilt sent to drawing apps, like a Wacom does.

Two apps: an **Android app** (the pad) and a **Mac menu-bar app** (receives the pen, moves the
cursor, draws the ink). They pair once, then talk over Wi-Fi, or over USB for the lowest lag.

**Status:** M0 feel test built (1 Oct 2026): the phone pad drives the Mac cursor over Wi-Fi,
with USB as an automatic fallback. Ink overlay is next (M1).

- [docs/research.md](docs/research.md): open-source projects that already do part of this, and
  what each one teaches us
- [docs/design.md](docs/design.md): architecture, transport, wire protocol, milestones, risks
- [docs/protocol.md](docs/protocol.md): the exact bytes on the wire

## M0 feel test

What it does:
- The S Pen hovering over the phone moves the Mac cursor.
- Touching the screen with the pen tip clicks or drags.
- The side button, pressed while hovering, right-clicks.
- **Several monitors:** the **display button** on the phone strip moves the pad to the next
  screen (main → others → **All displays** → main), and the pad takes that screen's shape. If you
  move the real mouse onto another screen while the pen is away, the pen follows it there.
- The phone's side strip shows which link is live (Wi-Fi or USB) and its round-trip time.
- The Mac prints frames per second, lost frames and jitter every 2 s.

Before the first run:
1. **Phone:** turn on USB debugging (Settings → Developer options), then connect it by cable,
   or use wireless debugging (`adb pair` / `adb connect`), so the app can be installed.
2. **Mac:** grant Accessibility to the terminal app you run this from (System Settings → Privacy
   & Security → Accessibility). Without it, macOS silently drops the cursor events.
3. Allow `qalam-m0` when the firewall asks about incoming connections.

Run:

```sh
scripts/m0.sh                # build both, install + open on the phone, run the receiver
scripts/m0.sh --display 1    # start on another display (list them: mac/.build/release/qalam-m0 --list-displays)
scripts/m0.sh --display all  # start with the pad spanning every display
scripts/m0.sh --no-follow    # don't jump to the screen the real mouse moves to
scripts/m0.sh --raw          # no smoothing, to compare
```

The phone finds the Mac by itself over Bonjour. If it doesn't, tap **Mac IP…** and type the
address that `qalam-m0` prints. To test the fallback, keep the cable in and turn Wi-Fi off on
the phone: the strip should switch to **USB** within about a second.

## Layout

```
android/   Kotlin app: full-screen pen pad, sender (Gradle wrapper, platform SDK only so far)
mac/       Swift package: qalam-m0 receiver now; the menu-bar app with the ink overlay comes in M1
scripts/   m0.sh: build + install + run
docs/      research, design, protocol
```
