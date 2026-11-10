package com.neuron.hf

import android.content.Context
import com.neuron.model.SecretStore

/** Token Hugging Face untuk model gated. Disimpan terenkripsi (SecretStore); token plaintext lama dimigrasi otomatis. */
class HfPrefs(ctx: Context) {
    private val secret = SecretStore(ctx, "hf")

    var token: String?
        get() = secret.get("token")?.takeIf { it.isNotBlank() }
        set(v) { secret.put("token", v?.trim()?.takeIf { it.isNotEmpty() }) }
}
