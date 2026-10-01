package ro.soluzy.qalam

import java.io.DataInputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/**
 * The phone's side of pairing (docs/protocol.md, "compare a 6-digit code"), on its own thread.
 * Talks UDP to a Mac on the network, or TCP to 127.0.0.1 for the Mac on the USB cable.
 */
class Pairer(private val target: InetSocketAddress, private val phoneName: String, private val listener: Listener) {

    /** Called on the pairing thread. */
    interface Listener {
        fun onCode(code: String, macName: String)
        fun onPaired(pairing: Pairing)
        fun onFailed(why: String)
    }

    @Volatile private var cancelled = false

    fun start() {
        thread(name = "qalam-pairing", isDaemon = true) {
            try {
                run()
            } catch (e: Exception) {
                if (!cancelled) listener.onFailed("Pairing stopped: ${e.message ?: e.javaClass.simpleName}")
            }
        }
    }

    fun cancel() {
        cancelled = true
    }

    private fun run() {
        Channel(target).use { ch ->
            val me = Crypto.x25519Pair()
            val name = phoneName.toByteArray().let { it.copyOf(minOf(it.size, 64)) }

            // 1–2: hello → the Mac's public key, its commitment, its id and name.
            val commit = ch.exchange(header(Wire.PAIR_HELLO) + me.public + byteArrayOf(name.size.toByte()) + name, Wire.PAIR_COMMIT, tries = 8)
                ?: return fail("The Mac didn't answer. On the Mac, open Qalam's menu → Pair a phone…, then try again.")
            if (commit.size < 24 + 73) return fail("The Mac's answer was malformed.")
            val pm = commit.copyOfRange(24, 56)
            val c = commit.copyOfRange(56, 88)
            val macId = commit.copyOfRange(88, 96)
            val macName = String(commit, 97, minOf(commit[96].toInt() and 0xFF, commit.size - 97))

            // 3–4: our nonce, polled until you decide on the Mac (up to 5 minutes).
            val np = Crypto.random(16)
            var key: ByteArray? = null
            val deadline = System.currentTimeMillis() + 5 * 60_000
            while (!cancelled && System.currentTimeMillis() < deadline) {
                val reveal = ch.exchange(header(Wire.PAIR_NONCE) + me.public + np, Wire.PAIR_REVEAL, tries = 6)
                    ?: return fail("Lost the Mac while pairing. Try again.")
                if (reveal.size < 24 + 17) return fail("The Mac's answer was malformed.")
                val nm = reveal.copyOfRange(24, 40)
                if (key == null) {
                    // The Mac committed to Nm before it saw our nonce: check it kept its word.
                    if (!Crypto.sha256("qalam commit v1".toByteArray(), pm, me.public, nm).contentEquals(c)) {
                        return fail("The Mac's answer didn't check out, so pairing stopped. Try again.")
                    }
                    key = Crypto.hkdf(Crypto.x25519(me.private, pm), np + nm, "qalam pairing v1")
                    val h = Crypto.sha256("qalam code v1".toByteArray(), me.public, pm, np, nm)
                    val n = (ByteBuffer.wrap(h, 0, 4).int.toLong() and 0xFFFFFFFFL) % 1_000_000
                    listener.onCode("%06d".format(n), macName)
                }
                when (reveal[40].toInt()) {
                    0 -> Thread.sleep(500) // waiting for you on the Mac
                    1 -> {
                        val result = reveal.copyOfRange(41, reveal.size)
                        val plain = Crypto.open(javax.crypto.spec.SecretKeySpec(key, "AES"), ByteArray(12), result,
                            "qalam pair result v1".toByteArray())
                        if (plain == null || plain.size < 12 || !plain.copyOfRange(4, 12).contentEquals(macId)) {
                            return fail("The Mac's confirmation didn't check out. Try again.")
                        }
                        val id = ByteBuffer.wrap(plain, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
                        listener.onPaired(Pairing(hex(macId), macName, id, key, listOf(target.address.hostAddress ?: "")))
                        return
                    }
                    else -> return fail("Pairing was refused on the Mac.")
                }
            }
        }
    }

    private fun fail(why: String) {
        if (!cancelled) listener.onFailed(why)
    }

    private fun header(type: Int) = Wire.header(type, 0, 0, 0)

    /** One request/answer path to the Mac, retried every 0.5 s. */
    private class Channel(private val target: InetSocketAddress) : AutoCloseable {
        private val usb = target.address.isLoopbackAddress
        private val udp = if (usb) null else DatagramSocket().apply { soTimeout = 500 }
        private val tcp = if (usb) Socket().apply { connect(target, 1000); soTimeout = 500; tcpNoDelay = true } else null

        fun exchange(request: ByteArray, expect: Int, tries: Int): ByteArray? {
            repeat(tries) {
                send(request)
                val deadline = System.currentTimeMillis() + 500
                while (System.currentTimeMillis() < deadline) {
                    val r = receive() ?: break
                    if (r.size >= 24 && r[0] == 0x51.toByte() && r[1] == 0x4C.toByte() && r[2] == 1.toByte() && r[3] == expect.toByte()) return r
                }
            }
            return null
        }

        private fun send(b: ByteArray) {
            if (udp != null) {
                udp.send(DatagramPacket(b, b.size, target))
            } else {
                tcp!!.getOutputStream().write(byteArrayOf((b.size and 0xFF).toByte(), (b.size shr 8).toByte()) + b)
            }
        }

        private fun receive(): ByteArray? = try {
            if (udp != null) {
                val buf = ByteArray(512)
                val p = DatagramPacket(buf, buf.size)
                udp.receive(p)
                buf.copyOf(p.length)
            } else {
                val input = DataInputStream(tcp!!.getInputStream())
                val len = input.readUnsignedByte() or (input.readUnsignedByte() shl 8)
                ByteArray(len).also { input.readFully(it) }
            }
        } catch (_: java.net.SocketTimeoutException) {
            null
        }

        override fun close() {
            udp?.close()
            tcp?.close()
        }
    }

    private companion object {
        fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    }
}
