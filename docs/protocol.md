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
- 10–11: screen snapshot request and chunks (below). Encrypted.

Either side drops a frame type it doesn't know (after it has decrypted), without an answer.

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

### Screen snapshot (types 10–11)

One still picture of the area the pad maps to, sent only when the phone asks for it (the
snapshot button on the strip). It is not a video stream.

| type | name | direction | body |
|---|---|---|---|
| 10 | snapshot-request | phone → Mac | `request u16` · `max_w u16` · `max_h u16` · `missing_count u16` · `missing_count` × `index u16` |
| 11 | snapshot-chunk | Mac → phone | `request u16` · `status u8` · `width u16` · `height u16` · `total_bytes u32` · `index u16` · `count u16` · `data` |

**Request:**
- `request` is an id the phone picks for each new picture (it counts up and wraps).
- `max_w` × `max_h` is the pad's size in screen pixels. The Mac scales the area down to fit it,
  keeping its shape, and never scales up: not past `max_w` × `max_h`, and not past the area's
  real pixels. It also caps the picture at about 2 megapixels.
- `missing_count` 0 asks for the whole picture. If `request` is the picture the Mac sent last,
  it sends that again without a new capture (so a lost request or a lost burst can simply be
  asked for again).
- `missing_count` > 0 asks for only those chunks of picture `request` again. The phone sends at
  most 500 indices per request.

**Chunks:**
- `status`: 0 ok, 1 no Screen Recording permission on the Mac, 2 the capture failed,
  3 too soon (a new picture less than 0.5 s after the last one), 4 this Mac app can't send
  pictures (`qalam-m0`), 5 the Mac no longer holds picture `request` (ask for a new one).
- With status 0: `data` is bytes `index × 1200 …` of a JPEG that is `total_bytes` long and
  `width` × `height` pixels, split into `count` chunks of 1200 bytes (the last one shorter).
  Every chunk repeats `width`, `height`, `total_bytes` and `count`, so any chunk can start the
  reassembly.
- With any other status: one chunk with `width`, `height`, `total_bytes`, `index` and `count`
  all 0 and no `data`. It is the final answer to that request.
- A chunk is at most 1215 bytes of payload, so 1255 bytes sealed: one UDP datagram under a
  1500-byte MTU (IPv4 or IPv6). USB carries the same frames with its `u16` length prefix.
- The Mac keeps the frame under about 300 KB (quality about 0.65, lower or smaller when needed),
  so a picture is at most about 250 chunks.

**Pacing and the replay window:**
- The Mac sends the chunks in order, a few per millisecond, so the phone's socket buffer
  doesn't overflow. It seals each chunk at the moment it sends it, so the counters on the
  session keep rising in sending order, pongs included, and an in-order burst never falls
  behind the 64-frame replay window.

**Reassembly on the phone:**
- It collects chunks of its current `request` and ignores any other.
- After a quiet gap (no chunk for 250 ms) with chunks missing, it asks for only those again,
  at most 4 times, then gives up with a short message.
- If nothing at all comes back within 1.2 s, it asks for the whole picture again (same
  `request`), at most twice. An old Mac drops type 10 without an answer, so the phone then
  says to update Qalam on the Mac.

**Rules on the Mac:**
- One phone (pairing) has one picture at a time: a new request stops the burst still going out
  for the previous one, and the last picture is kept for resends until the next one.
- A new picture less than 0.5 s after the last capture gets status 3; asking again for the
  picture just sent (whole or chunks) isn't limited.
- The capture leaves out Qalam's own windows (the ink overlay), because the phone draws its own
  copy of the ink on top, and the mouse pointer.
- A test instance (`QALAM_PORT` set) with `QALAM_TEST_SNAPSHOT=<image file>` answers with that
  image, scaled the same way, instead of capturing the screen.

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
