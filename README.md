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

**Status:** design stage. Nothing is built yet.

- [docs/research.md](docs/research.md): open-source projects that already do part of this, and
  what each one teaches us
- [docs/design.md](docs/design.md): architecture, transport, wire protocol, milestones, risks

## Planned layout

```
android/   Kotlin app: full-screen pen pad, sender
mac/       Swift / SwiftUI menu-bar app: receiver, cursor control, ink overlay
docs/      research + design
```
