package ro.soluzy.qalam

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.spec.NamedParameterSpec
import java.security.spec.XECPrivateKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Vectors made with Python's `cryptography` straight from docs/protocol.md; a Python phone built
 * the same way pairs and talks with the Mac app, so passing these means the phone does too.
 */
class CryptoTest {
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }

    private val phonePriv = hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
    private val macPriv = hex("65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384")
    private val pp = hex("07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c")
    private val pm = hex("5714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c36")
    private val shared = hex("c9ea6a3f79a000b60b076d4afc990b272f3f0b5aaa3f0b8713c209273e363863")
    private val k = hex("1e6131eae02a8a6d56bcdfe34ba2495821ae5986c126e3f3083bcd27ef393453")
    private val commit = hex("146be7d7d021820e1e02f7a7f6384c823326277a107df5156ab876716d0901c8")
    private val tx = hex("8106c4c2c15cc61684b8421afa669aade01af92a69e6fec7a4ec7d77fbea3dcb")
    private val header = hex("514c0102d4c3b2a1efcdab89674523010500000000000000")
    private val sealed = hex("02f8e90248e950f96b90ca8d9459563f1e06685ce85b7461a7")
    private val result = hex("eff6271b32af3cf79114c55cabc2d8ea3650116749b27cb6bfbfa5f3")
    private val np = ByteArray(16) { 7 }
    private val nm = ByteArray(16) { 9 }
    private val session = 0x0123456789ABCDEFL

    private fun priv(raw: ByteArray) = KeyFactory.getInstance("XDH").generatePrivate(XECPrivateKeySpec(NamedParameterSpec.X25519, raw))

    @Test
    fun x25519SharedSecretMatchesBothWays() {
        assertArrayEquals(shared, Crypto.x25519(priv(phonePriv), pm))
        assertArrayEquals(shared, Crypto.x25519(priv(macPriv), pp))
    }

    @Test
    fun pairingKeyCodeAndCommitment() {
        assertArrayEquals(k, Crypto.hkdf(shared, np + nm, "qalam pairing v1"))
        assertArrayEquals(commit, Crypto.sha256("qalam commit v1".toByteArray(), pm, pp, nm))
        val h = Crypto.sha256("qalam code v1".toByteArray(), pp, pm, np, nm)
        val code = (ByteBuffer.wrap(h, 0, 4).int.toLong() and 0xFFFFFFFFL) % 1_000_000
        assertEquals("313297", "%06d".format(code))
    }

    @Test
    fun sessionKeyHeaderAndSealedFrame() {
        val salt = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(session).array()
        assertArrayEquals(tx, Crypto.hkdf(k, salt, "qalam v1 phone to mac"))
        assertArrayEquals(header, Wire.header(Wire.PING, 0xA1B2C3D4.toInt(), session, 5))
        val key = SecretKeySpec(tx, "AES")
        assertArrayEquals(sealed, Crypto.seal(key, Crypto.nonce(5), "hello pen".toByteArray(), header))
        assertArrayEquals("hello pen".toByteArray(), Crypto.open(key, Crypto.nonce(5), sealed, header))
        val tampered = sealed.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertNull(Crypto.open(key, Crypto.nonce(5), tampered, header))
        val h = Wire.parseHeader(header, header.size)!!
        assertEquals(Wire.PING, h.type)
        assertEquals(0xA1B2C3D4.toInt(), h.pairing)
        assertEquals(session, h.session)
        assertEquals(5L, h.counter)
    }

    @Test
    fun pairResultOpensWithK() {
        val plain = Crypto.open(SecretKeySpec(k, "AES"), ByteArray(12), result, "qalam pair result v1".toByteArray())!!
        assertEquals(0xA1B2C3D4.toInt(), ByteBuffer.wrap(plain, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int)
        assertArrayEquals(ByteArray(8) { it.toByte() }, plain.copyOfRange(4, 12))
    }

    @Test
    fun replayWindowAcceptsEachCounterOnce() {
        val w = ReplayWindow()
        assertFalse(w.accept(0))
        assertTrue(w.accept(1))
        assertFalse(w.accept(1))
        assertTrue(w.accept(10))
        assertTrue(w.accept(5)) // reordered, inside the window
        assertFalse(w.accept(5))
        assertTrue(w.accept(200))
        assertFalse(w.accept(100)) // older than the window
        assertTrue(w.accept(150))
    }

    @Test
    fun freshKeysAgree() {
        val a = Crypto.x25519Pair()
        val b = Crypto.x25519Pair()
        assertEquals(32, a.public.size)
        assertArrayEquals(Crypto.x25519(a.private, b.public), Crypto.x25519(b.private, a.public))
    }
}
