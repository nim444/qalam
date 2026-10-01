# Wire protocol

## v0 (M0 + M1, unencrypted)

**Port 47474** on the Mac, on both transports:

| Transport | Phone → Mac | Found by | Framing |
|---|---|---|---|
| **Wi-Fi** (preferred) | UDP to the Mac's LAN address | Bonjour `_qalam._udp`, or an IP typed on the phone | one frame per datagram |
| **USB** (fallback) | TCP to the phone's own `127.0.0.1` | `adb reverse tcp:47474 tcp:47474`, kept in place by the Mac receiver | `u16` little-endian length, then the frame |

The phone pings both links every 250 ms. Pen frames go to Wi-Fi while it has answered within
the last second. Otherwise they go to USB, and back to Wi-Fi once it answers again. If neither
link answers yet, they keep going to Wi-Fi.

All integers are little-endian.

```
header (8 bytes): 'Q' 'L' | version u8 = 0 | type u8 | counter u32
```

`counter` counts frames on one link (each link has its own counter, and pings use it too).
The Mac reads gaps in it as lost frames.

| type | name | direction | body |
|---|---|---|---|
| 1 | pen | phone → Mac | `count u8` then `count` × sample (16 bytes) |
| 2 | ping | phone → Mac | `t_ns i64` (phone `System.nanoTime`) · `last_rtt_us u32` (shown in the Mac log) |
| 3 | pong | Mac → phone | `t_ns i64` (echoed) · `display_w u16` · `display_h u16` · `index u8` · `count u8` · `name_len u8` · `name` (UTF-8, ≤ 64 bytes) · `mode u8` · `tool u8` · `color u8` · `size u8` · `ink_strokes u16` · `ink_history u16` |
| 4 | display | phone → Mac | `action u8`: 1 = move the pad to the next display |
| 5 | control | phone → Mac | `cmd u8` · `value u8` (see below) |

The pong describes the area the pad maps to:
- its size in points, so the phone can give its pad the same shape
- its place in the display cycle: `index` 0 … `count − 1` is one display, and `index == count`
  means all displays as one surface
- its name, shown on the phone's display button

The last four bytes are the strip state: the Mac owns it (the phone, the menu and the hotkeys
all change it), and the phone's strip follows it. `mode` 0 = cursor, 1 = ink; `tool` 0 pen,
1 highlighter, 2 laser, 3 eraser; `color` an index into the shared palette (red, yellow, green,
blue, black, white); `size` 0 small, 1 medium, 2 large.

`ink_strokes` and `ink_history` are how many strokes the Mac's ink shows and how many undo
steps it holds. The phone draws its own copy of the ink as you write, and uses these two numbers
to follow undo, clear and fade-away done on the Mac (menu, hotkeys). It only adjusts once the pen
has been quiet for a moment.

**Control commands** (type 5): `cmd` 1 mode, 2 tool, 3 colour, 4 size (each with the new value),
5 undo, 6 clear (value ignored). Choosing a tool or a colour also switches to Ink mode.

The cycle runs main display → the others → all displays → main again. The phone sees a switch
in the next pong, within 250 ms. (Pongs from the first M0 build stop after `display_h`, and the
phone accepts both, and pongs from `qalam-m0` carry a default state.)

**Sample (16 bytes):**

| field | type | meaning |
|---|---|---|
| `t_us` | u32 | phone clock, µs since the pad opened (wraps after ~71 min; use wrapping subtraction) |
| `x`, `y` | u16 | position on the pad, 0 … 65535 = left/top … right/bottom edge |
| `pressure` | u16 | 0 … 65535 |
| `tilt_x`, `tilt_y` | i16 | hundredths of a degree |
| `flags` | u8 | bit0 in range (hovering or touching) · bit1 touching · bit2 side button · bit3 eraser |
| — | u8 | reserved, 0 |

A pen frame holds one Android `MotionEvent`: its historical samples, oldest first, then the
current one. When the pen leaves the screen (hover exit not followed by a touch within 80 ms,
or the app pausing), the phone sends one sample with `flags = 0`.

## v1: M2 (planned)

- AEAD on every frame (ChaCha20-Poly1305, key from QR pairing). The `counter` grows to `u64`
  and also serves as the nonce and the replay guard.
- UDP pen frames repeat the previous frame's samples, so one lost datagram leaves no gap in the
  ink. The receiver drops duplicates by `t_us`.
- Control messages (mode, tool, colour, undo, clear) as a new type with a small JSON body.
