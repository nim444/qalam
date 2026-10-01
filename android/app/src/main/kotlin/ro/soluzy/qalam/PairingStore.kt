package ro.soluzy.qalam

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The Mac this phone is paired with. [id] is the pairing number (u32) from the Mac. */
class Pairing(val macId: String, val macName: String, val id: Int, val key: ByteArray, val hosts: List<String>)

/**
 * Keeps the pairing in the app's private preferences. The pairing key itself is wrapped with an
 * AES key that lives in the Android Keystore and never leaves it.
 */
object PairingStore {
    private const val PREFS = "pairing"
    private const val ALIAS = "qalam-pairing-wrap"

    fun load(context: Context): Pairing? {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val macId = p.getString("macId", null) ?: return null
        val wrapped = p.getString("key", null) ?: return null
        val iv = p.getString("iv", null) ?: return null
        val key = try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, b64(iv)))
                doFinal(b64(wrapped))
            }
        } catch (_: Exception) {
            return null // the Keystore key is gone (e.g. after a restore to a new phone): pair again
        }
        return Pairing(macId, p.getString("macName", "Mac")!!, p.getInt("id", 0), key,
            p.getString("hosts", "")!!.split(',').filter { it.isNotBlank() })
    }

    fun save(context: Context, pairing: Pairing) {
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, wrapKey()) }
        val wrapped = c.doFinal(pairing.key)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("macId", pairing.macId)
            .putString("macName", pairing.macName)
            .putInt("id", pairing.id)
            .putString("key", b64(wrapped))
            .putString("iv", b64(c.iv))
            .putString("hosts", pairing.hosts.joinToString(","))
            .apply()
    }

    /** Remembers where the Mac answered last, for when Bonjour finds nothing. */
    fun rememberHost(context: Context, host: String) {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val hosts = listOf(host) + p.getString("hosts", "")!!.split(',').filter { it.isNotBlank() && it != host }
        p.edit().putString("hosts", hosts.take(3).joinToString(",")).apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(ALIAS) }
    }

    private fun wrapKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build()
            )
        }.generateKey()
    }

    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)
    private fun b64(s: String) = Base64.decode(s, Base64.NO_WRAP)
}
