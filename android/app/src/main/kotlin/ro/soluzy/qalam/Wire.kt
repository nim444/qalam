package ro.soluzy.qalam

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Wire format v1 (docs/protocol.md): a 24-byte header, then the payload sealed with AES-256-GCM
 * (Link does the sealing); pairing messages travel in the clear (Pairer). The builders here make
 * payloads only.
 */
object Wire {
    const val PORT = 47474
    const val SERVICE_TYPE = "_qalam._udp"
    const val VERSION = 1
    const val HEADER = 24 // "QL" | version | type | pairing u32 | session u64 | counter u64
    const val SAMPLE = 16
    const val MAX_SAMPLES = 64

    const val PEN = 1
    const val PING = 2
    const val PONG = 3
    const val DISPLAY = 4
    const val CONTROL = 5
    const val PAIR_HELLO = 6
    const val PAIR_COMMIT = 7
    const val PAIR_NONCE = 8
    const val PAIR_REVEAL = 9

    // Control commands (frame type 5)
    const val CMD_MODE = 1
    const val CMD_TOOL = 2
    const val CMD_COLOR = 3
    const val CMD_SIZE = 4
    const val CMD_UNDO = 5
    const val CMD_CLEAR = 6

    // Sample flags
    const val IN_RANGE = 0x01
    const val TOUCHING = 0x02
    const val BUTTON = 0x04
    const val ERASER = 0x08

    /** Little-endian view of [bytes], positioned at [at]. */
    fun le(bytes: ByteArray, at: Int = 0): ByteBuffer =
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).also { it.position(at) }

    fun header(type: Int, pairing: Int, session: Long, counter: Long): ByteArray =
        ByteArray(HEADER).also {
            le(it).put(0x51).put(0x4C).put(VERSION.toByte()).put(type.toByte()).putInt(pairing).putLong(session).putLong(counter)
        }

    class Header(val type: Int, val pairing: Int, val session: Long, val counter: Long)

    fun parseHeader(bytes: ByteArray, len: Int): Header? {
        if (len < HEADER || bytes[0] != 0x51.toByte() || bytes[1] != 0x4C.toByte() || bytes[2] != VERSION.toByte()) return null
        val b = le(bytes, 3)
        val type = b.get().toInt() and 0xFF
        return Header(type, b.int, b.long, b.long)
    }

    fun ping(tNs: Long, lastRttUs: Int): ByteArray = ByteArray(12).also { le(it).putLong(tNs).putInt(lastRttUs) }

    /** Asks the Mac to move the pad to the next display (… → all displays → first). */
    fun nextDisplay(): ByteArray = byteArrayOf(1)

    /** A strip command for the Mac; for mode, tool, colour and size [value] is the new choice. */
    fun control(cmd: Int, value: Int = 0): ByteArray = byteArrayOf(cmd.toByte(), value.toByte())

    /**
     * The Mac's strip state, sent in every pong: mode 0 cursor / 1 ink, tool, colour and size
     * indices, and how many strokes and undo steps its ink has (for following undo/clear done there).
     */
    data class PadState(val mode: Int, val tool: Int, val color: Int, val size: Int, val inkStrokes: Int? = null, val inkHistory: Int? = null)

    class Pong(
        val tNs: Long,
        val displayW: Int,
        val displayH: Int,
        val displayIndex: Int, // == displayCount means "all displays"
        val displayCount: Int,
        val displayName: String,
        val state: PadState?,
    )

    /** A decrypted pong payload. */
    fun parsePong(p: ByteArray): Pong? {
        if (p.size < 15) return null
        val b = le(p)
        val t = b.long
        val w = b.short.toInt() and 0xFFFF
        val h = b.short.toInt() and 0xFFFF
        val index = b.get().toInt() and 0xFF
        val count = b.get().toInt() and 0xFF
        val nameLen = minOf(b.get().toInt() and 0xFF, p.size - 15)
        val name = String(p, 15, nameLen, Charsets.UTF_8)
        val s = 15 + nameLen
        fun u8(i: Int) = p[i].toInt() and 0xFF
        val state = when {
            p.size >= s + 8 -> PadState(u8(s), u8(s + 1), u8(s + 2), u8(s + 3), u8(s + 4) or (u8(s + 5) shl 8), u8(s + 6) or (u8(s + 7) shl 8))
            p.size >= s + 4 -> PadState(u8(s), u8(s + 1), u8(s + 2), u8(s + 3))
            else -> null
        }
        return Pong(t, w, h, index, count, name, state)
    }
}
