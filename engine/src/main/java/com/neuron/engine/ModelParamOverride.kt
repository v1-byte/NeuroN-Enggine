package com.neuron.engine

import com.neuron.model.ChatParams
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Parameter generate yang khusus untuk SATU model (kunci: nama berkas GGUF). Hanya bidang yang diisi yang
 * menimpa; bidang null berarti "ikut sumber lain" (chat/params.json > Modelfile > generation_config > bawaan).
 * Penimpas ini menang atas semuanya karena dipilih sengaja untuk model tersebut.
 *
 * Kunci JSON sama dengan field [ChatParams] (camelCase). Hanya bidang sampling dan konteks; system prompt,
 * stop sequence, dan penalti kehadiran/frekuensi tetap dari proyek.
 */
data class ModelParamOverride(
    val temperature: Float? = null,
    val topP: Float? = null,
    val topK: Int? = null,
    val minP: Float? = null,
    val repeatPenalty: Float? = null,
    val maxTokens: Int? = null,
    val seed: Long? = null,
    val contextLength: Int? = null,
) {
    val isEmpty: Boolean get() = this == ModelParamOverride()

    fun applyTo(p: ChatParams): ChatParams = p.copy(
        temperature = temperature ?: p.temperature,
        topP = topP ?: p.topP,
        topK = topK ?: p.topK,
        minP = minP ?: p.minP,
        repeatPenalty = repeatPenalty ?: p.repeatPenalty,
        maxTokens = maxTokens ?: p.maxTokens,
        seed = seed ?: p.seed,
        contextLength = contextLength ?: p.contextLength,
    )

    /** Pesan untuk nilai pertama yang tidak valid, atau null bila semuanya valid. Rentang mengikuti ChatParams.validate. */
    fun problem(): String? = when {
        temperature != null && temperature !in 0f..5f -> "temperature harus 0..5"
        topP != null && topP !in 0f..1f -> "topP harus 0..1"
        topK != null && topK < 0 -> "topK tidak boleh negatif"
        minP != null && minP !in 0f..1f -> "minP harus 0..1"
        repeatPenalty != null && repeatPenalty <= 0f -> "repeatPenalty harus > 0"
        maxTokens != null && maxTokens <= 0 -> "maxTokens harus > 0"
        contextLength != null && contextLength < MIN_CONTEXT -> "contextLength minimal $MIN_CONTEXT"
        else -> null
    }

    /** Bidang yang terisi saja, untuk dikirim ke UI. */
    fun toMap(): Map<String, Any> = buildMap {
        temperature?.let { put("temperature", it.toDouble()) }
        topP?.let { put("topP", it.toDouble()) }
        topK?.let { put("topK", it) }
        minP?.let { put("minP", it.toDouble()) }
        repeatPenalty?.let { put("repeatPenalty", it.toDouble()) }
        maxTokens?.let { put("maxTokens", it) }
        seed?.let { put("seed", it) }
        contextLength?.let { put("contextLength", it) }
    }

    fun toJson(): String = buildJsonObject {
        temperature?.let { put("temperature", it) }
        topP?.let { put("topP", it) }
        topK?.let { put("topK", it) }
        minP?.let { put("minP", it) }
        repeatPenalty?.let { put("repeatPenalty", it) }
        maxTokens?.let { put("maxTokens", it) }
        seed?.let { put("seed", it) }
        contextLength?.let { put("contextLength", it) }
    }.toString()

    companion object {
        /** Sama dengan batas muat di LlamaCppEngine (contextLength < 256 ditolak saat model dimuat). */
        const val MIN_CONTEXT = 256

        private val KEYS = setOf("temperature", "topP", "topK", "minP", "repeatPenalty", "maxTokens", "seed", "contextLength")

        /**
         * Baca JSON dari UI atau penyimpanan. Ketat: kunci tidak dikenal, tipe salah, atau nilai di luar rentang
         * melempar IllegalArgumentException dengan pesan yang bisa ditampilkan. Teks kosong = tanpa penimpas.
         */
        fun fromJson(text: String): ModelParamOverride {
            if (text.isBlank()) return ModelParamOverride()
            val o = Json.parseToJsonElement(text) as? JsonObject
                ?: throw IllegalArgumentException("Parameter harus berupa objek JSON.")
            val unknown = o.keys - KEYS
            require(unknown.isEmpty()) { "Kunci tidak dikenal: ${unknown.sorted().joinToString()}" }

            fun prim(k: String): JsonPrimitive? {
                val v = o[k]
                if (v == null || v is JsonNull) return null
                val p = v as? JsonPrimitive ?: throw IllegalArgumentException("$k harus berupa angka.")
                require(!p.isString) { "$k harus berupa angka." }
                return p
            }
            fun float(k: String) = prim(k)?.let { it.floatOrNull ?: throw IllegalArgumentException("$k harus berupa angka.") }
            fun int(k: String) = prim(k)?.let { it.intOrNull ?: throw IllegalArgumentException("$k harus berupa bilangan bulat.") }
            fun long(k: String) = prim(k)?.let { it.longOrNull ?: throw IllegalArgumentException("$k harus berupa bilangan bulat.") }

            val r = ModelParamOverride(
                temperature = float("temperature"), topP = float("topP"), topK = int("topK"), minP = float("minP"),
                repeatPenalty = float("repeatPenalty"), maxTokens = int("maxTokens"), seed = long("seed"),
                contextLength = int("contextLength"),
            )
            r.problem()?.let { throw IllegalArgumentException(it) }
            return r
        }
    }
}
