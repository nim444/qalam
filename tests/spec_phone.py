"""A phone written from docs/protocol.md alone, run against a test instance of the Mac app.

It pairs (the test instance accepts the code by itself), then checks that encrypted frames get
answered and that everything else is ignored: old v0 frames, replays, tampered frames, wrong
keys, unknown pairings and counters older than the replay window.

    QALAM_PORT=47480 QALAM_TEST_AUTOPAIR=1 mac/build/Qalam.app/Contents/MacOS/Qalam &
    QALAM_PORT=47480 python3 tests/spec_phone.py      # needs: pip install cryptography
"""
import hashlib
import os
import socket
import struct
import sys
import time

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

PORT = int(os.environ.get("QALAM_PORT", "47480"))
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

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
