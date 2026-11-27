package com.neuron.engine

import android.content.Context
import com.neuron.model.ChatParams
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.withLock
import java.io.File

/**
 * Penyimpanan parameter generate per model. Disimpan di SharedPreferences privat aplikasi, kunci = NAMA berkas
 * GGUF (bukan path), isinya JSON [ModelParamOverride]. Sengaja di luar project.json: project.json berlaku untuk
 * model mana pun yang aktif, sedangkan penimpas ini mengikuti modelnya.
 *
 * Konsekuensi memakai nama berkas: mengganti nama model memutus penimpasnya, dan salinan hasil edit
 * (`<nama>-edited-<waktu>.gguf`) mulai tanpa penimpas.
 */
internal object ModelParamStore {
    private const val PREFS = "neuron_model_params"

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Null bila belum ada atau isinya rusak (data rusak tidak boleh mematikan chat). */
    fun get(ctx: Context, modelName: String): ModelParamOverride? =
        prefs(ctx).getString(modelName, null)
            ?.let { runCatching { ModelParamOverride.fromJson(it) }.getOrNull() }
            ?.takeUnless { it.isEmpty }

    fun set(ctx: Context, modelName: String, o: ModelParamOverride) {
        val e = prefs(ctx).edit()
        if (o.isEmpty) e.remove(modelName) else e.putString(modelName, o.toJson())
        e.commit()
    }
}

internal object ModelParamsBridge {
    private fun paramsMap(p: ChatParams): Map<String, Any> = mapOf(
        "temperature" to p.temperature.toDouble(), "topP" to p.topP.toDouble(), "topK" to p.topK,
        "minP" to p.minP.toDouble(), "repeatPenalty" to p.repeatPenalty.toDouble(),
        "maxTokens" to p.maxTokens, "seed" to p.seed, "contextLength" to p.contextLength,
    )

    /** {name, active, overrides: {…bidang terisi…}, base: {…nilai dari proyek tanpa penimpas…}, effective: {…}}. */
    fun state(ctx: Context, file: File): Map<String, Any?> {
        val p = ProjectStore.load(ctx)
        val saved = ModelParamStore.get(ctx, file.name)
        val base = ModelDefaults.base(p)
        return mapOf(
            "name" to file.name,
            "active" to (file.absolutePath == p.files.modelPath),
            "overrides" to (saved?.toMap() ?: emptyMap<String, Any>()),
            "base" to paramsMap(base),
            "effective" to paramsMap((saved ?: ModelParamOverride()).applyTo(base)),
        )
    }

    /** Simpan penimpas dari JSON UI. JSON kosong atau {} = hapus. Nilai tidak valid = error berisi pesan. */
    fun save(ctx: Context, file: File, json: String): Map<String, Any?> {
        val o = ModelParamOverride.fromJson(json)
        ModelParamStore.set(ctx, file.name, o)
        return state(ctx, file)
    }

    fun clear(ctx: Context, file: File): Map<String, Any?> {
        ModelParamStore.set(ctx, file.name, ModelParamOverride())
        return state(ctx, file)
    }

    /**
     * Uji cepat pada model AKTIF dengan nilai dari form (belum perlu disimpan). Parameter dihitung dari nilai proyek
     * (tanpa penimpas tersimpan) lalu ditimpa nilai form, jadi bidang yang dikosongkan di form kembali ke nilai proyek.
     * contextLength dikunci ke konteks yang benar-benar termuat: perubahan konteks baru berlaku setelah disimpan,
     * karena model harus dimuat ulang. Engine mentah dipakai (tanpa tools/guardrail), seperti uji A/B LoRA.
     */
    fun test(ctx: Context, file: File, prompt: String, json: String, maxTokens: Int): Map<String, Any?> =
        runBlocking(Dispatchers.IO) {
            require(prompt.isNotBlank()) { "Tulis prompt uji dulu." }
            require(prompt.length <= 4000) { "Prompt uji maksimal 4000 karakter." }
            val p = ProjectStore.load(ctx)
            require(file.absolutePath == p.files.modelPath) {
                "Uji cepat memakai model aktif. Jadikan model ini aktif dulu di tab Kelola."
            }
            val form = ModelParamOverride.fromJson(json)
            val loadedCtx = ModelDefaults.effective(p).contextLength
            val cap = maxTokens.coerceIn(16, 512)
            val tuned = form.applyTo(ModelDefaults.base(p)).let { it.copy(contextLength = loadedCtx, maxTokens = minOf(it.maxTokens, cap)) }
            val engine = EngineHub.ensure(p)
            val sb = StringBuilder()
            EngineHub.gate.withLock {
                engine.chat(listOf(ChatMessage("user", prompt)), tuned).collect { sb.append(it) }
            }
            val st = engine.lastStats
            mapOf(
                "text" to sb.toString().trim(),
                "tokens" to (st?.completionTokens ?: 0),
                "ms" to (st?.millis ?: 0L),
                "tps" to Math.round((st?.tokensPerSecond ?: 0.0) * 10.0) / 10.0,
                "contextPinned" to (form.contextLength != null && form.contextLength != loadedCtx),
            )
        }
}
