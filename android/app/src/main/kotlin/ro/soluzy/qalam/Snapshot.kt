package ro.soluzy.qalam

import kotlin.random.Random

/**
 * Collects the chunks of one snapshot picture (docs/protocol.md, types 10–11). Chunks of another
 * request, or that disagree with the first one about the picture, are ignored.
 */
class SnapshotAssembler(val request: Int) {
    var width = 0
        private set
    var height = 0
        private set
    var total = 0
        private set
    var count = 0
        private set
    var received = 0
        private set
    private var parts = arrayOfNulls<ByteArray>(0)

    val complete: Boolean get() = count > 0 && received == count

    /** Takes [c] if it belongs here and is new. */
    fun offer(c: Wire.SnapshotChunk): Boolean {
        if (c.request != request || c.status != 0) return false
        if (c.count !in 1..MAX_CHUNKS || c.total !in 1..MAX_BYTES || c.index >= c.count) return false
        if (count == 0) {
            width = c.width
            height = c.height
            total = c.total
            count = c.count
            parts = arrayOfNulls(c.count)
        } else if (c.count != count || c.total != total || c.width != width || c.height != height) {
            return false
        }
        if (parts[c.index] != null) return false
        parts[c.index] = c.data
        received++
        return true
    }

    /** Indices still missing, at most [limit] (one request's worth). */
    fun missing(limit: Int = MAX_MISSING): List<Int> {
        val out = ArrayList<Int>()
        for (i in parts.indices) {
            if (parts[i] == null) out += i
            if (out.size == limit) break
        }
        return out
    }

    /** The JPEG once complete, or null if the pieces don't add up to [total]. */
    fun bytes(): ByteArray? {
        if (!complete) return null
        val out = ByteArray(total)
        var at = 0
        for (p in parts) {
            if (p == null || at + p.size > total) return null
            System.arraycopy(p, 0, out, at, p.size)
            at += p.size
        }
        return if (at == total) out else null
    }

    companion object {
        const val MAX_CHUNKS = 4096
        const val MAX_BYTES = 4 shl 20
        const val MAX_MISSING = 500 // fits one request datagram
    }
}

/**
 * Fetches one snapshot: sends the request, collects chunks, asks again for only the missing ones
 * after a quiet gap, and gives up with a plain message. No clock or threads of its own: the
 * caller passes the time and calls [tick] every ~50 ms while [busy], so it runs the same in tests.
 * [send] gets request payloads; [onResult] is called once per picture, on whichever thread
 * finished it.
 */
class SnapshotFetcher(
    private val send: (ByteArray) -> Unit,
    private val onResult: (Result) -> Unit,
) {
    sealed interface Result
    class Done(val jpeg: ByteArray, val width: Int, val height: Int) : Result
    /** [noAnswer]: nothing came back at all (an old Mac app, or the link is down). */
    class Failed(val message: String, val noAnswer: Boolean = false) : Result

    private var nextId = Random.nextInt(0x10000)
    private var asm: SnapshotAssembler? = null
    private var maxW = 0
    private var maxH = 0
    private var sentAt = 0L
    private var lastChunkAt = 0L
    private var fullTries = 0
    private var resendRounds = 0

    val busy: Boolean @Synchronized get() = asm != null

    /** 0…1 while a picture is arriving. */
    val progress: Float
        @Synchronized get() = asm?.let { if (it.count == 0) 0f else it.received.toFloat() / it.count } ?: 0f

    @Synchronized
    fun start(maxW: Int, maxH: Int, nowMs: Long) {
        val id = nextId
        nextId = (nextId + 1) and 0xFFFF
        asm = SnapshotAssembler(id)
        this.maxW = maxW
        this.maxH = maxH
        fullTries = 1
        resendRounds = 0
        sentAt = nowMs
        lastChunkAt = 0
        send(Wire.snapshotRequest(id, maxW, maxH))
    }

    @Synchronized
    fun cancel() {
        asm = null
    }

    fun onChunk(c: Wire.SnapshotChunk, nowMs: Long) {
        val result = synchronized(this) {
            val a = asm ?: return
            if (c.request != a.request) return
            if (c.status != 0) return@synchronized finish(Failed(message(c.status)))
            if (a.offer(c)) lastChunkAt = nowMs
            if (!a.complete) return
            val jpeg = a.bytes() ?: return@synchronized finish(Failed(LOST))
            finish(Done(jpeg, a.width, a.height))
        }
        onResult(result)
    }

    fun tick(nowMs: Long) {
        val result = synchronized(this) {
            val a = asm ?: return
            if (a.received == 0) {
                // Nothing yet: the request or the whole burst was lost, or the Mac doesn't know type 10.
                if (nowMs - sentAt < NO_ANSWER_MS) return
                if (fullTries >= FULL_TRIES) return@synchronized finish(Failed(NO_ANSWER, noAnswer = true))
                fullTries++
                sentAt = nowMs
                send(Wire.snapshotRequest(a.request, maxW, maxH))
                return
            }
            if (nowMs - lastChunkAt < QUIET_MS || nowMs - sentAt < QUIET_MS) return
            if (resendRounds >= RESEND_ROUNDS) return@synchronized finish(Failed(LOST))
            resendRounds++
            sentAt = nowMs
            send(Wire.snapshotRequest(a.request, maxW, maxH, a.missing()))
            return
        }
        onResult(result)
    }

    private fun finish(r: Result): Result {
        asm = null
        return r
    }

    companion object {
        const val QUIET_MS = 250L      // no chunk for this long = the rest were lost
        const val NO_ANSWER_MS = 1200L // a capture takes ~0.1 s; this allows for a slow Mac
        const val FULL_TRIES = 3
        const val RESEND_ROUNDS = 4

        const val NO_ANSWER = "No answer from the Mac. Update Qalam on the Mac?"
        const val LOST = "The picture didn't come through. Tap to try again."

        fun message(status: Int) = when (status) {
            1 -> "Allow Screen Recording for Qalam on the Mac"
            2 -> "The Mac couldn't capture the screen"
            3 -> "Too quick. Tap again."
            4 -> "This Mac app can't send the screen. Use the Qalam app."
            5 -> "The Mac no longer has that picture. Tap again."
            else -> "The Mac couldn't send the screen"
        }
    }
}
