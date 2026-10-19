package ro.soluzy.qalam

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** The snapshot's wire payloads, chunk reassembly and the missing-chunk resends (docs/protocol.md). */
class SnapshotTest {
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }

    private val jpeg = Random(7).nextBytes(5000) // 5 chunks: 4 × 1200 + 200

    private fun chunk(index: Int, request: Int = 0x0102, status: Int = 0, data: ByteArray = jpeg) = Wire.SnapshotChunk(
        request, status, 640, 400, data.size, index, (data.size + 1199) / 1200,
        data.copyOfRange(index * 1200, minOf((index + 1) * 1200, data.size)),
    )

    @Test fun requestLayout() {
        assertArrayEquals(hex("3412" + "d007" + "1405" + "0000"), Wire.snapshotRequest(0x1234, 2000, 1300))
        assertArrayEquals(hex("3412" + "d007" + "1405" + "0200" + "0100" + "0102"), Wire.snapshotRequest(0x1234, 2000, 1300, listOf(1, 513)))
    }

    @Test fun chunkLayout() {
        val c = Wire.parseSnapshotChunk(hex("0201" + "00" + "8002" + "9001" + "88130000" + "0300" + "0500" + "aabb"))!!
        assertEquals(0x0102, c.request)
        assertEquals(0, c.status)
        assertEquals(640, c.width)
        assertEquals(400, c.height)
        assertEquals(5000, c.total)
        assertEquals(3, c.index)
        assertEquals(5, c.count)
        assertArrayEquals(hex("aabb"), c.data)
        assertNull(Wire.parseSnapshotChunk(ByteArray(14)))
    }

    @Test fun reassemblesInAnyOrder() {
        val a = SnapshotAssembler(0x0102)
        for (i in listOf(4, 0, 2, 1)) assertTrue(a.offer(chunk(i)))
        assertFalse(a.complete)
        assertEquals(listOf(3), a.missing())
        assertFalse("a duplicate is not new", a.offer(chunk(2)))
        assertFalse("another request's chunk is ignored", a.offer(chunk(3, request = 9)))
        assertTrue(a.offer(chunk(3)))
        assertTrue(a.complete)
        assertArrayEquals(jpeg, a.bytes())
        assertEquals(640, a.width)
    }

    @Test fun ignoresChunksThatDisagree() {
        val a = SnapshotAssembler(0x0102)
        assertTrue(a.offer(chunk(0)))
        val other = Random(8).nextBytes(7000)
        assertFalse("a different total/count", a.offer(chunk(1, data = other)))
        assertFalse("an index past count", a.offer(Wire.SnapshotChunk(0x0102, 0, 640, 400, 5000, 5, 5, ByteArray(1))))
        assertFalse("an error status is not data", a.offer(chunk(1, status = 2)))
        assertEquals(listOf(1, 2, 3, 4), a.missing())
        assertEquals(listOf(1, 2), a.missing(limit = 2))
    }

    @Test fun piecesThatDontAddUpAreRefused() {
        val a = SnapshotAssembler(1)
        a.offer(Wire.SnapshotChunk(1, 0, 10, 10, 100, 0, 2, ByteArray(60)))
        a.offer(Wire.SnapshotChunk(1, 0, 10, 10, 100, 1, 2, ByteArray(60)))
        assertTrue(a.complete)
        assertNull(a.bytes())
    }

    /** A fetcher with its requests and results captured, and its request id read from the first request. */
    private class Rig {
        val sent = mutableListOf<ByteArray>()
        val results = mutableListOf<SnapshotFetcher.Result>()
        val f = SnapshotFetcher(send = { sent += it }, onResult = { results += it })
        val id get() = (sent[0][0].toInt() and 0xFF) or ((sent[0][1].toInt() and 0xFF) shl 8)
        fun missing(req: ByteArray): List<Int> {
            val b = Wire.le(req, 6)
            val n = b.short.toInt()
            return List(n) { b.short.toInt() and 0xFFFF }
        }
    }

    @Test fun asksForOnlyTheMissingChunksAfterAQuietGap() {
        val r = Rig()
        r.f.start(640, 400, nowMs = 0)
        assertEquals(1, r.sent.size)
        assertEquals(0, r.missing(r.sent[0]).size)
        for (i in listOf(0, 2, 4)) r.f.onChunk(chunk(i, request = r.id), nowMs = 20)
        assertEquals(0.6f, r.f.progress, 0.001f)
        r.f.tick(nowMs = 100)
        assertEquals("still inside the quiet gap", 1, r.sent.size)
        r.f.tick(nowMs = 20 + SnapshotFetcher.QUIET_MS)
        assertEquals(2, r.sent.size)
        assertEquals(listOf(1, 3), r.missing(r.sent[1]))
        r.f.onChunk(chunk(1, request = r.id), nowMs = 300)
        r.f.onChunk(chunk(3, request = r.id), nowMs = 300)
        val done = r.results.single() as SnapshotFetcher.Done
        assertArrayEquals(jpeg, done.jpeg)
        assertEquals(640, done.width)
        assertFalse(r.f.busy)
    }

    @Test fun retriesTheWholeRequestThenSaysNoAnswer() {
        val r = Rig()
        r.f.start(640, 400, nowMs = 0)
        r.f.tick(nowMs = SnapshotFetcher.NO_ANSWER_MS)
        r.f.tick(nowMs = 2 * SnapshotFetcher.NO_ANSWER_MS)
        assertEquals(3, r.sent.size)
        assertTrue("same request each time", r.sent.all { it.contentEquals(r.sent[0]) })
        assertTrue(r.results.isEmpty())
        r.f.tick(nowMs = 3 * SnapshotFetcher.NO_ANSWER_MS)
        val failed = r.results.single() as SnapshotFetcher.Failed
        assertTrue(failed.noAnswer)
        assertTrue(failed.message.contains("Update Qalam on the Mac"))
    }

    @Test fun givesUpAfterAFewResendRounds() {
        val r = Rig()
        r.f.start(640, 400, nowMs = 0)
        r.f.onChunk(chunk(0, request = r.id), nowMs = 10)
        var now = 10L
        repeat(SnapshotFetcher.RESEND_ROUNDS) {
            now += SnapshotFetcher.QUIET_MS
            r.f.tick(now)
        }
        assertEquals(1 + SnapshotFetcher.RESEND_ROUNDS, r.sent.size)
        assertTrue(r.results.isEmpty())
        r.f.tick(now + SnapshotFetcher.QUIET_MS)
        assertEquals(SnapshotFetcher.LOST, (r.results.single() as SnapshotFetcher.Failed).message)
    }

    @Test fun anErrorStatusEndsTheRequest() {
        val r = Rig()
        r.f.start(640, 400, nowMs = 0)
        r.f.onChunk(Wire.SnapshotChunk(r.id xor 1, 1, 0, 0, 0, 0, 0, ByteArray(0)), nowMs = 5)
        assertTrue("another request's answer is ignored", r.results.isEmpty())
        r.f.onChunk(Wire.SnapshotChunk(r.id, 1, 0, 0, 0, 0, 0, ByteArray(0)), nowMs = 5)
        assertEquals("Allow Screen Recording for Qalam on the Mac", (r.results.single() as SnapshotFetcher.Failed).message)
        assertFalse(r.f.busy)
    }

    @Test fun cancelledFetchIgnoresLateChunks() {
        val r = Rig()
        r.f.start(640, 400, nowMs = 0)
        r.f.cancel()
        for (i in 0 until 5) r.f.onChunk(chunk(i, request = r.id), nowMs = 10)
        r.f.tick(nowMs = 5000)
        assertTrue(r.results.isEmpty())
        assertEquals(1, r.sent.size)
    }
}
