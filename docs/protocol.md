# Wire protocol

## v0: M0 feel test (built 1 Oct 2026, unencrypted)

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
| 3 | pong | Mac → phone | `t_ns i64` (echoed) · `display_w u16` · `display_h u16` (target display in points) |

The pong carries the display size so the phone can give its pad the same shape.

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
