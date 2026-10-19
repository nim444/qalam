"""A phone written from docs/protocol.md alone, run against a test instance of the Mac app.

It pairs (the test instance accepts the code by itself), then checks that encrypted frames get
answered and that everything else is ignored: old v0 frames, replays, tampered frames, wrong
keys, unknown pairings and counters older than the replay window.

With QALAM_TEST_SNAPSHOT set it also checks the screen snapshot (types 10-11). The test writes a
made-up PNG to that path, and the Mac answers snapshot requests with it instead of capturing the
screen, so the real display is never recorded:

    export QALAM_PORT=47480 QALAM_TEST_SNAPSHOT=/tmp/qalam-snapshot.png
    QALAM_TEST_AUTOPAIR=1 mac/build/Qalam.app/Contents/MacOS/Qalam &
    python3 tests/spec_phone.py      # needs: pip install cryptography
"""
import hashlib
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import zlib

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

PORT = int(os.environ.get("QALAM_PORT", "47480"))
SNAPSHOT = os.environ.get("QALAM_TEST_SNAPSHOT")
IMG_W, IMG_H = 1440, 900


def write_png(path, w, h):
    """A gradient with a checkerboard and some noise, so the JPEG has real work to do."""
    rows = bytearray()
    for y in range(h):
        rows.append(0)  # filter: none
        g = y * 255 // h
        for x in range(w):
            noise = ((x * 7919 + y * 104729) * 2654435761 >> 16) & 63
            rows += bytes((x * 255 // w, g ^ (noise >> 1), (200 if (x // 48 + y // 48) % 2 else 40) ^ noise))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))


if SNAPSHOT:
    write_png(SNAPSHOT, IMG_W, IMG_H)  # before the Mac is asked for it

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(0.6)
results = []


def send(b):
    sock.sendto(b, ("127.0.0.1", PORT))


def recv():
    try:
        return sock.recvfrom(4096)[0]
    except socket.timeout:
        return None


def header(t, pairing=0, session=0, counter=0):
    return b"QL" + bytes([1, t]) + struct.pack("<IQQ", pairing, session, counter)


def hkdf(ikm, salt, info):
    return HKDF(algorithm=SHA256(), length=32, salt=salt, info=info).derive(ikm)


def nonce(c):
    return b"\0\0\0\0" + struct.pack("<Q", c)


def check(name, ok):
    results.append(ok)
    print(("PASS  " if ok else "FAIL  ") + name)


def ping_payload():
    return struct.pack("<qI", time.monotonic_ns(), 900)


def pong_state(p):
    n = p[14]
    s = p[15 + n:]
    return {"w": struct.unpack("<H", p[8:10])[0], "mode": s[0]}


# Wait for the app to start listening.
for _ in range(20):
    send(header(6) + bytes(33))
    if recv():
        break
    time.sleep(0.5)

# An old v0 frame gets no answer.
send(b"QL\x00\x02" + struct.pack("<IqI", 1, time.monotonic_ns(), 0))
check("v0 frame ignored", recv() is None)

# Pairing.
priv = X25519PrivateKey.generate()
pp = priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
name = b"Spec Phone"
send(header(6) + pp + bytes([len(name)]) + name)
r = recv()
check("pair-commit received", r is not None and r[3] == 7)
if r is None:
    sys.exit(1)
body = r[24:]
pm, commitment, mac_id = body[0:32], body[32:64], body[64:72]
np_ = os.urandom(16)
nm = result = None
for _ in range(20):
    send(header(8) + pp + np_)
    r = recv()
    if r and r[3] == 9:
        nm, status = r[24:40], r[40]
        if status == 1:
            result = r[41:]
            break
    time.sleep(0.3)
check("commitment matches the revealed nonce", nm is not None and hashlib.sha256(b"qalam commit v1" + pm + pp + nm).digest() == commitment)
check("pairing accepted", result is not None and len(result) == 28)
if result is None:
    sys.exit(1)
K = hkdf(priv.exchange(X25519PublicKey.from_public_bytes(pm)), np_ + nm, b"qalam pairing v1")
plain = AESGCM(K).decrypt(b"\0" * 12, result, b"qalam pair result v1")
pairing = struct.unpack("<I", plain[:4])[0]
check("pair result decrypts with our key and names the same Mac", plain[4:12] == mac_id)

# Encrypted frames on a session.
session = int.from_bytes(os.urandom(8), "little")
salt = struct.pack("<Q", session)
k_tx = AESGCM(hkdf(K, salt, b"qalam v1 phone to mac"))
k_rx = AESGCM(hkdf(K, salt, b"qalam v1 mac to phone"))
counter = [0]


def sealed(t, payload, key=k_tx, c=None):
    if c is None:
        counter[0] += 1
        c = counter[0]
    h = header(t, pairing, session, c)
    return h + key.encrypt(nonce(c), payload, h)


def opened(r):
    h = r[:24]
    return k_rx.decrypt(nonce(struct.unpack("<Q", h[16:24])[0]), r[24:], h)


frame = sealed(2, ping_payload())
send(frame)
r = recv()
check("encrypted ping answered", r is not None and r[3] == 3)
check("pong decrypts", r is not None and pong_state(opened(r))["mode"] == 0)
send(frame)
check("replayed frame ignored", recv() is None)
bad = bytearray(sealed(2, ping_payload()))
bad[30] ^= 1
send(bytes(bad))
check("tampered frame ignored", recv() is None)
send(sealed(2, ping_payload(), key=AESGCM(os.urandom(32))))
check("wrong key ignored", recv() is None)
h = header(2, pairing ^ 0x5555, session, 999)
send(h + k_tx.encrypt(nonce(999), ping_payload(), h))
check("unknown pairing ignored", recv() is None)
send(sealed(5, bytes([1, 1])))  # control: Ink mode
time.sleep(0.1)
send(sealed(2, ping_payload()))
r = recv()
check("a control command shows in the next pong", r is not None and pong_state(opened(r))["mode"] == 1)
send(sealed(5, bytes([1, 0])))
send(sealed(2, ping_payload(), c=counter[0] + 50))
a = recv()
send(sealed(2, ping_payload(), c=counter[0] + 40))
b = recv()
check("a reordered frame inside the window is accepted", a is not None and b is not None)
send(sealed(2, ping_payload(), c=1))
check("a frame older than the window is ignored", recv() is None)

send(sealed(12, b"\x01"))
check("an unknown frame type is ignored", recv() is None)


# Screen snapshot (types 10-11), on fresh sessions.
class Session:
    def __init__(self):
        self.id = int.from_bytes(os.urandom(8), "little")
        salt = struct.pack("<Q", self.id)
        self.tx = AESGCM(hkdf(K, salt, b"qalam v1 phone to mac"))
        self.rx = AESGCM(hkdf(K, salt, b"qalam v1 mac to phone"))
        self.counter = 0
        self.top, self.seen = 0, 0  # replay window, as the phone keeps it

    def seal(self, t, payload):
        self.counter += 1
        h = header(t, pairing, self.id, self.counter)
        return h + self.tx.encrypt(nonce(self.counter), payload, h)

    def open(self, r):
        c = struct.unpack("<Q", r[16:24])[0]
        return c, r[3], self.rx.decrypt(nonce(c), r[24:], r[:24])

    def accept(self, c):
        """The 64-frame replay window from docs/protocol.md."""
        if c > self.top:
            shift = c - self.top
            self.seen = 1 if shift >= 64 else ((self.seen << shift) | 1) & (2**64 - 1)
            self.top = c
            return True
        d = self.top - c
        if d >= 64 or self.seen >> d & 1:
            return False
        self.seen |= 1 << d
        return True


def snap_request(rid, w, h, missing=()):
    return struct.pack("<HHHH", rid, w, h, len(missing)) + b"".join(struct.pack("<H", i) for i in missing)


def snap_chunk(p):
    rid, status, w, h, total, index, count = struct.unpack("<HBHHIHH", p[:15])
    return dict(rid=rid, status=status, w=w, h=h, total=total, index=index, count=count, data=p[15:])


class Burst:
    """What arrived for one session: chunks by request id, plus everything the window saw."""
    def __init__(self):
        self.chunks = {}
        self.sizes, self.accepted = [], []

    def add(self, sess, frame, drop=lambda c: False):
        self.sizes.append(len(frame))
        c, t, p = sess.open(frame)
        self.accepted.append(sess.accept(c))
        if t == 11:
            ch = snap_chunk(p)
            if not drop(ch):
                self.chunks.setdefault(ch["rid"], {})[ch["index"]] = ch


def collect_udp(sess, burst, quiet=0.4, drop=lambda c: False):
    sock.settimeout(quiet)
    while (r := recv()) is not None:
        burst.add(sess, r, drop)
    sock.settimeout(0.6)
    return burst


def jpeg_of(chunks):
    first = next(iter(chunks.values()))
    if first["status"] != 0 or len(chunks) != first["count"]:
        return None
    return b"".join(chunks[i]["data"] for i in range(first["count"]))


def jpeg_size(b):
    """(width, height) from the JPEG's SOF marker."""
    i = 2
    while i + 9 < len(b) and b[i] == 0xFF:
        m = b[i + 1]
        if m in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", b[i + 5:i + 9])
            return w, h
        i += 2 + struct.unpack(">H", b[i + 2:i + 4])[0]
    return None


def decodes(b, w, h):
    """sips (macOS) reads the JPEG back; elsewhere the markers have to do."""
    if not shutil.which("sips"):
        return True
    with tempfile.NamedTemporaryFile(suffix=".jpg") as f:
        f.write(b)
        f.flush()
        out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", f.name], capture_output=True, text=True).stdout
    return f"pixelWidth: {w}" in out and f"pixelHeight: {h}" in out


if not SNAPSHOT:
    print("SKIP  snapshot tests (set QALAM_TEST_SNAPSHOT, see the top of this file)")
else:
    s1 = Session()
    send(s1.seal(10, snap_request(1, 1200, 750)))
    b = collect_udp(s1, Burst())
    got = b.chunks.get(1, {})
    first = next(iter(got.values()), None)
    pic = jpeg_of(got) if got else None
    check("snapshot: the whole picture arrives", first is not None and first["status"] == 0 and pic is not None)
    if pic is None:
        print(f"\n{sum(results)}/{len(results)} passed")
        sys.exit(1)
    count, total = first["count"], first["total"]
    print(f"      {first['w']}x{first['h']}, {total} bytes in {count} chunks, largest datagram {max(b.sizes)} bytes")
    check("snapshot: scaled to fit the pad (1440x900 into 1200x750)", (first["w"], first["h"]) == (1200, 750))
    check("snapshot: every chunk agrees on size, total and count",
          all((c["w"], c["h"], c["total"], c["count"]) == (1200, 750, total, count) for c in got.values()))
    check("snapshot: count and total_bytes match the data", count == (total + 1199) // 1200 and len(pic) == total)
    check("snapshot: a JPEG (FFD8 ... FFD9) of the stated size",
          pic[:2] == b"\xff\xd8" and pic[-2:] == b"\xff\xd9" and jpeg_size(pic) == (1200, 750))
    check("snapshot: the JPEG decodes", decodes(pic, 1200, 750))
    check("snapshot: each chunk fits one datagram (<= 1255 bytes)", max(b.sizes) <= 1255)
    check("snapshot: the replay window accepts the whole burst", all(b.accepted))

    want = [0, 3, count - 1]
    send(s1.seal(10, snap_request(1, 1200, 750, want)))
    r = collect_udp(s1, Burst()).chunks.get(1, {})
    check("snapshot: only the missing chunks are sent again, unchanged",
          sorted(r) == want and all(r[i]["data"] == got[i]["data"] for i in want))

    # A new picture, with chunks dropped on purpose, then asked for again.
    time.sleep(0.5)
    send(s1.seal(10, snap_request(2, 1200, 750)))
    send(s1.seal(10, snap_request(3, 1200, 750)))  # right after: too soon
    b = collect_udp(s1, Burst(), drop=lambda c: c["rid"] == 2 and c["index"] % 5 == 1)
    soon = b.chunks.get(3, {})
    check("snapshot: a new picture within 0.5 s is refused as too soon",
          list(soon) == [0] and soon[0]["status"] == 3 and soon[0]["count"] == 0 and soon[0]["data"] == b"")
    got2 = b.chunks.get(2, {})
    lost = sorted(set(range(count)) - set(got2))
    check("snapshot: chunks were dropped on purpose", len(lost) > 0 and len(got2) > 0)
    send(s1.seal(10, snap_request(2, 1200, 750, lost)))
    collect_udp(s1, b)
    pic2 = jpeg_of(b.chunks.get(2, {}))
    check("snapshot: the dropped chunks come back and the picture is whole",
          pic2 is not None and pic2[:2] == b"\xff\xd8" and pic2[-2:] == b"\xff\xd9" and jpeg_size(pic2) == (1200, 750))

    send(s1.seal(10, snap_request(2, 1200, 750)))
    again = collect_udp(s1, Burst()).chunks.get(2, {})
    check("snapshot: asking again for the same picture resends it (not too soon)", jpeg_of(again) == pic2)

    send(s1.seal(10, snap_request(77, 1200, 750, [0])))
    gone = collect_udp(s1, Burst()).chunks.get(77, {})
    check("snapshot: a resend of a picture the Mac doesn't hold says so", 0 in gone and gone[0]["status"] == 5)

    time.sleep(0.5)
    send(s1.seal(10, snap_request(4, 4000, 2500)))
    big = collect_udp(s1, Burst()).chunks.get(4, {})
    pic4 = jpeg_of(big)
    check("snapshot: never scaled up (asked 4000x2500, the image is 1440x900)",
          pic4 is not None and jpeg_size(pic4) == (IMG_W, IMG_H) and big[0]["w"] == IMG_W)

    # The same frames over USB: TCP with a u16 length in front of each frame.
    time.sleep(0.5)
    s2 = Session()
    t = socket.create_connection(("127.0.0.1", PORT), timeout=2)
    frame = s2.seal(10, snap_request(5, 640, 400))
    t.sendall(struct.pack("<H", len(frame)) + frame)
    b = Burst()
    t.settimeout(0.6)
    buf = b""
    try:
        while True:
            data = t.recv(65536)
            if not data:
                break
            buf += data
            while len(buf) >= 2 and len(buf) - 2 >= (n := struct.unpack("<H", buf[:2])[0]):
                b.add(s2, buf[2:2 + n])
                buf = buf[2 + n:]
    except socket.timeout:
        pass
    t.close()
    pic5 = jpeg_of(b.chunks.get(5, {})) if b.chunks.get(5) else None
    check("snapshot over USB (TCP framing)", pic5 is not None and jpeg_size(pic5) == (640, 400) and all(b.accepted))

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
