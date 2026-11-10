package com.neuron.server

import android.content.Context
import com.neuron.model.SecretStore

/** Pengaturan server lokal (port, API key) dan status terakhir. API key disimpan terenkripsi (SecretStore). */
class ServerPrefs(ctx: Context) {
    private val p = ctx.getSharedPreferences("server", Context.MODE_PRIVATE)
    private val secret = SecretStore(ctx, "server")

    var port: Int
        get() = p.getInt("port", 8080)
        set(v) { p.edit().putInt("port", v).apply() }

    var apiKey: String
        get() = secret.get("apiKey") ?: ""
        set(v) { secret.put("apiKey", v.trim()) }

    var enabled: Boolean
        get() = p.getBoolean("enabled", false)
        set(v) { p.edit().putBoolean("enabled", v).apply() }

    companion object { const val MIN_KEY_LENGTH = 8 }
}
