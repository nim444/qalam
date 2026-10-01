package ro.soluzy.qalam

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Wire format v0, as used by the M0 feel test (unencrypted). Spec: docs/protocol.md. */
object Wire {
    const val PORT = 47474
    const val SERVICE_TYPE = "_qalam._udp"
    const val HEADER = 8 // "QL" | version | type | counter u32
    const val SAMPLE = 16
    const val MAX_SAMPLES = 64

    const val PEN = 1
    const val PING = 2
    const val PONG = 3
    const val DISPLAY = 4
    const val CONTROL = 5

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

    /** Writes the 8-byte header in place; pen frames are built with room left for it. */
    fun header(frame: ByteArray, type: Int, counter: Int) {
        le(frame).put(0x51).put(0x4C).put(0).put(type.toByte()).putInt(counter)
    }

    fun ping(counter: Int, tNs: Long, lastRttUs: Int): ByteArray {
        val frame = ByteArray(HEADER + 12)
        header(frame, PING, counter)
        le(frame, HEADER).putLong(tNs).putInt(lastRttUs)
        return frame
    }

    /** Asks the Mac to move the pad to the next display (… → all displays → first). */
    fun nextDisplay(): ByteArray = ByteArray(HEADER + 1).also { it[HEADER] = 1 }

    /** A strip command for the Mac; for mode, tool, colour and size [value] is the new choice. */
    fun control(cmd: Int, value: Int = 0): ByteArray =
        ByteArray(HEADER + 2).also { it[HEADER] = cmd.toByte(); it[HEADER + 1] = value.toByte() }

    /** The Mac's strip state, sent in every pong: mode 0 cursor / 1 ink, tool, colour and size indices. */
    data class PadState(val mode: Int, val tool: Int, val color: Int, val size: Int)

    class Pong(
        val tNs: Long,
        val displayW: Int,
        val displayH: Int,
        val displayIndex: Int, // == displayCount means "all displays"
        val displayCount: Int,
        val displayName: String,
        val state: PadState?, // null from a Mac without ink (qalam-m0 sends defaults)
    )

    fun parsePong(bytes: ByteArray, len: Int): Pong? {
        if (len < HEADER + 12) return null
        val b = le(bytes)
        if (b.get() != 0x51.toByte() || b.get() != 0x4C.toByte() || b.get() != 0.toByte() || b.get() != PONG.toByte()) {
            return null
        }
        b.int // Mac's counter, unused
        val t = b.long
        val w = b.short.toInt() and 0xFFFF
        val h = b.short.toInt() and 0xFFFF
        if (len < HEADER + 15) return Pong(t, w, h, 0, 1, "", null)
        val index = b.get().toInt() and 0xFF
        val count = b.get().toInt() and 0xFF
        val nameLen = minOf(b.get().toInt() and 0xFF, len - HEADER - 15)
        val name = String(bytes, HEADER + 15, nameLen, Charsets.UTF_8)
        val s = HEADER + 15 + nameLen
        val state = if (len >= s + 4) {
            PadState(bytes[s].toInt() and 0xFF, bytes[s + 1].toInt() and 0xFF, bytes[s + 2].toInt() and 0xFF, bytes[s + 3].toInt() and 0xFF)
        } else null
        return Pong(t, w, h, index, count, name, state)
    }
}
