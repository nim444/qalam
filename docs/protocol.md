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

## v1 (M2): paired and encrypted

v1 replaces v0 on the wire; a Mac running v1 drops v0 frames. The payloads of the pen, ping,
pong, display and control frames are the same as in v0. Only the header changes, and the payload
is encrypted.

**Header (24 bytes, in the clear, authenticated):**

```
'Q' 'L' | version u8 = 1 | type u8 | pairing u32 | session u64 | counter u64
```

**Frame types:**
- 1–5: pen, ping, pong, display, control. Encrypted, with the same payloads as v0.
- 6–9: pairing messages (below). In the clear, with pairing, session and counter all 0.

### Encrypted frames

```
body    = AES-256-GCM(key, nonce, payload, aad = the 24-byte header) → ciphertext ‖ tag (16)
nonce   = 4 zero bytes ‖ counter u64 LE
key     = HKDF-SHA256(ikm = pairing key K, salt = session as 8 bytes LE,
                      info = "qalam v1 phone to mac" | "qalam v1 mac to phone", length 32)
```

- **Sessions:** each time the phone connects a link, it picks a random 64-bit session for that
  link. Wi-Fi and USB get separate sessions.
- **Counters:** the phone counts its frames from 1. The Mac answers on the same session with
  its own counter, also from 1. Every (key, nonce) pair is therefore used once.
- **Replays:** each side keeps the highest counter seen per session plus a 64-frame window,
  so UDP reordering is fine. It drops repeated or older counters, and it only updates the
  window after the frame has decrypted.
- **Unknown or bad frames:** a frame with an unknown pairing, or one that fails to decrypt, is
  dropped without an answer.

### Pairing: compare a 6-digit code

This works like Bluetooth Secure Simple Pairing's "numeric comparison". The Mac answers
pairing messages only while its **Pair a phone…** window is open.

```
1  phone → Mac  pair-hello   Pp (X25519 public key, 32) ‖ name_len u8 ‖ name (UTF-8)
2  Mac → phone  pair-commit  Pm (32) ‖ C (32) ‖ mac_id (8) ‖ name_len u8 ‖ name
                             C = SHA-256("qalam commit v1" ‖ Pm ‖ Pp ‖ Nm), Nm = 16 random bytes
3  phone → Mac  pair-nonce   Pp (32) ‖ Np (16 random bytes)        (repeated every 0.5 s as a poll)
4  Mac → phone  pair-reveal  Nm (16) ‖ status u8 [‖ result (28)]
                             status: 0 waiting for you, 1 accepted, 2 refused
```

**What the messages prove:**
- The phone checks that C matches Nm.
- The Mac commits to Nm before it sees Np. So a device in the middle can't pick values that make
  the two codes match, except by a one-in-a-million guess.

**What both sides compute:**

```
code   = u32 big-endian of the first 4 bytes of SHA-256("qalam code v1" ‖ Pp ‖ Pm ‖ Np ‖ Nm), mod 1 000 000
K      = HKDF-SHA256(ikm = X25519 shared secret, salt = Np ‖ Nm, info = "qalam pairing v1", length 32)
result = AES-256-GCM(K, nonce = 12 zero bytes, aad = "qalam pair result v1",
                     plaintext = pairing u32 LE ‖ mac_id (8))  → ciphertext ‖ tag = 28 bytes
```

- Both screens show the code, and you click **Pair** on the Mac only if they match.
- The Mac then sends `result`. The phone can only decrypt it if it holds the same K, which
  proves the key, and it gets the pairing number to put in its headers.
- Each message is retried every 0.5 s until it's answered. The Mac answers a repeat with the
  same reply.

**Where the keys live:**
- **Mac:** `~/Library/Application Support/Qalam/pairings.json` (mode 0600). It holds the Mac's
  `mac_id` and one `{id, name, key}` per paired phone. Forgetting a phone deletes its key.
- **Phone:** K is wrapped with an Android Keystore AES key (non-exportable) and kept in the
  app's private preferences. Forget erases it.

**Finding the Mac:** the Bonjour service `_qalam._udp` carries the TXT records `id` = mac_id
(16 hex digits) and `v` = 1. A paired phone only uses the Mac with its `id`. When Bonjour
finds nothing, it tries the addresses where it last reached that Mac.
