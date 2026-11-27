package com.neuron.model

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Penyimpanan rahasia (API key, token HF) terenkripsi AES-256 (kunci di Android Keystore).
 * Nilai lama di SharedPreferences plaintext dimigrasi sekali lalu dihapus dari file lama.
 * Tidak pernah jatuh ke plaintext: bila penyimpanan terenkripsi rusak, nilai dianggap kosong (pengguna isi ulang).
 */
class SecretStore(ctx: Context, name: String) {
    private val app = ctx.applicationContext
    private val secure: SharedPreferences? = open(name)
    private val legacy = app.getSharedPreferences(name, Context.MODE_PRIVATE)

    private fun open(name: String): SharedPreferences? {
        fun create() = EncryptedSharedPreferences.create(
            app, name + "_secure",
            MasterKey.Builder(app).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
        return runCatching { create() }.getOrElse {
            // keystore/berkas rusak: buang berkas terenkripsi lalu coba sekali lagi
            runCatching { app.deleteSharedPreferences(name + "_secure") }
            runCatching { create() }.getOrNull()
        }
    }

    fun get(key: String): String? {
        val s = secure ?: return null
        s.getString(key, null)?.let { return it }
        val old = legacy.getString(key, null)
        if (old != null) {                       // migrasi dari plaintext
            s.edit().putString(key, old).apply()
            legacy.edit().remove(key).apply()
        }
        return old
    }

    fun put(key: String, value: String?) {
        val s = secure ?: return
        s.edit().apply { if (value.isNullOrEmpty()) remove(key) else putString(key, value) }.apply()
        legacy.edit().remove(key).apply()
    }
}
