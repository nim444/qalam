package ro.soluzy.qalam

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.spec.NamedParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Wire v1 crypto (docs/protocol.md): X25519, HKDF-SHA256, AES-256-GCM, SHA-256. Platform JCA only. */
object Crypto {
    private val rng = SecureRandom()

    fun random(n: Int) = ByteArray(n).also { rng.nextBytes(it) }
    fun randomLong(): Long = rng.nextLong()

    fun sha256(vararg parts: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").run { parts.forEach { update(it) }; digest() }

    private fun hmac(key: ByteArray, vararg data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            data.forEach { update(it) }
            doFinal()
        }

    /** HKDF-SHA256 (RFC 5869) with a 32-byte output. */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: String): ByteArray = hmac(hmac(salt, ikm), info.toByteArray(), byteArrayOf(1))

    /** 4 zero bytes ‖ counter u64 LE. */
    fun nonce(counter: Long): ByteArray =
        ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).putInt(0).putLong(counter).array()

    /** AES-256-GCM: ciphertext ‖ 16-byte tag. */
    fun seal(key: SecretKeySpec, nonce: ByteArray, plain: ByteArray, aad: ByteArray): ByteArray =
        Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce))
            updateAAD(aad)
            doFinal(plain)
        }

    /** The plaintext, or null if the data was forged or damaged. */
    fun open(key: SecretKeySpec, nonce: ByteArray, sealed: ByteArray, aad: ByteArray): ByteArray? = try {
        Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, nonce))
            updateAAD(aad)
            doFinal(sealed)
        }
    } catch (_: GeneralSecurityException) {
        null
    }

    class X25519Pair(val private: PrivateKey, val public: ByteArray)

    fun x25519Pair(): X25519Pair {
        val gen = KeyPairGenerator.getInstance("XDH")
        runCatching { gen.initialize(NamedParameterSpec.X25519) } // X25519 is the default where this isn't accepted
        val kp = gen.generateKeyPair()
        return X25519Pair(kp.private, kp.public.encoded.copyOfRange(kp.public.encoded.size - 32, kp.public.encoded.size))
    }

    /** X25519(our private key, their raw 32-byte public key). */
    fun x25519(private: PrivateKey, peer: ByteArray): ByteArray {
        val pub = KeyFactory.getInstance("XDH").generatePublic(X509EncodedKeySpec(X25519_SPKI + peer))
        return KeyAgreement.getInstance("XDH").run {
            init(private)
            doPhase(pub, true)
            generateSecret()
        }
    }

    // The fixed DER prefix of an X25519 SubjectPublicKeyInfo, before the 32 key bytes.
    private val X25519_SPKI = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00)
}

/** Accepts each counter once: the highest so far plus a 64-frame window below it. Call it only after decrypting. */
class ReplayWindow {
    private var top = 0L
    private var seen = 0L

    @Synchronized
    fun accept(c: Long): Boolean {
        if (c <= 0) return false
        if (c > top) {
            val shift = c - top
            seen = if (shift >= 64) 1 else (seen shl shift.toInt()) or 1
            top = c
            return true
        }
        val d = top - c
        if (d >= 64 || (seen ushr d.toInt()) and 1L == 1L) return false
        seen = seen or (1L shl d.toInt())
        return true
    }
}
