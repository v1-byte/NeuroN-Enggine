package com.neuron.engine

import com.neuron.model.AiProject
import com.neuron.model.ChatParams
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull

/**
 * Menyatukan sumber parameter generate agar KEDUA engine (lokal & API) membaca file yang sama di editor:
 *   chat/params.json  >  model/Modelfile  >  model/generation_config.json  >  bawaan ChatParams()
 * Aturan: nilai di chat/params.json yang SAMA dengan bawaan dianggap "belum diatur", sehingga Modelfile /
 * generation_config boleh mengisinya. Nilai yang sudah diubah pengguna selalu menang.
 * Ditambah: tokenizer/tokenizer.json -> special.eos ikut menjadi stop sequence.
 * Semua pemanggil engine memakai [effective], bukan `project.chat` langsung.
 */
object ModelDefaults {
    private val BASE = ChatParams()

    class Parsed(
        val system: String? = null,
        val temperature: Float? = null, val topP: Float? = null, val topK: Int? = null, val minP: Float? = null,
        val repeatPenalty: Float? = null, val presencePenalty: Float? = null, val frequencyPenalty: Float? = null,
        val maxTokens: Int? = null, val seed: Long? = null, val contextLength: Int? = null,
        val stop: List<String> = emptyList(),
    )

    private fun unquote(s: String): String =
        if (s.length >= 2 && s.startsWith("\"") && s.endsWith("\"")) s.substring(1, s.length - 1) else s

    /** Membaca SYSTEM dan PARAMETER (temperature, top_p, top_k, min_p, repeat_penalty, presence_penalty,
     *  frequency_penalty, num_predict, seed, num_ctx, stop). FROM/TEMPLATE/ADAPTER diabaikan di sini. */
    fun parseModelfile(text: String): Parsed {
        var system: String? = null
        val num = HashMap<String, String>()
        val stops = ArrayList<String>()
        val lines = text.lines()
        var i = 0
        while (i < lines.size) {
            val line = lines[i].trim(); i++
            if (line.isEmpty() || line.startsWith("#")) continue
            val sp = line.indexOfFirst { it.isWhitespace() }
            if (sp < 0) continue
            val cmd = line.substring(0, sp).uppercase()
            val rest = line.substring(sp).trim()
            if (cmd == "SYSTEM") {
                if (rest.startsWith("\"\"\"")) {
                    val sb = StringBuilder(rest.substring(3))
                    var closed = sb.endsWith("\"\"\"")
                    if (closed) sb.setLength(sb.length - 3)
                    while (!closed && i < lines.size) {
                        sb.append('\n').append(lines[i]); i++
                        if (sb.endsWith("\"\"\"")) { sb.setLength(sb.length - 3); closed = true }
                    }
                    system = sb.toString().trim()
                } else system = unquote(rest)
            } else if (cmd == "PARAMETER") {
                val s2 = rest.indexOfFirst { it.isWhitespace() }
                if (s2 < 0) continue
                val name = rest.substring(0, s2).lowercase()
                val v = unquote(rest.substring(s2).trim())
                if (name == "stop") stops += v else num[name] = v
            }
        }
        return Parsed(
            system = system?.takeIf { it.isNotBlank() },
            temperature = num["temperature"]?.toFloatOrNull(),
            topP = num["top_p"]?.toFloatOrNull(),
            topK = num["top_k"]?.toIntOrNull(),
            minP = num["min_p"]?.toFloatOrNull(),
            repeatPenalty = num["repeat_penalty"]?.toFloatOrNull(),
            presencePenalty = num["presence_penalty"]?.toFloatOrNull(),
            frequencyPenalty = num["frequency_penalty"]?.toFloatOrNull(),
            maxTokens = num["num_predict"]?.toIntOrNull()?.takeIf { it > 0 },
            seed = num["seed"]?.toLongOrNull(),
            contextLength = num["num_ctx"]?.toIntOrNull()?.takeIf { it > 0 },
            stop = stops.filter { it.isNotEmpty() },
        )
    }

    /** Membaca generation_config.json gaya HF: temperature, top_p, top_k, min_p, repetition_penalty,
     *  max_new_tokens, do_sample=false (-> temperature 0). Field lain diabaikan. */
    fun parseGenerationConfig(text: String): Parsed {
        val o = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return Parsed()
        fun prim(k: String) = o[k] as? JsonPrimitive
        val sample = prim("do_sample")?.booleanOrNull
        return Parsed(
            temperature = if (sample == false) 0f else prim("temperature")?.floatOrNull,
            topP = prim("top_p")?.floatOrNull,
            topK = prim("top_k")?.intOrNull,
            minP = prim("min_p")?.floatOrNull,
            repeatPenalty = prim("repetition_penalty")?.floatOrNull,
            maxTokens = prim("max_new_tokens")?.intOrNull?.takeIf { it > 0 },
        )
    }

    private fun <T> pick(cur: T, def: T, a: T?, b: T?): T = if (cur != def) cur else (a ?: b ?: cur)

    /** Parameter generate akhir untuk [p]. Dipakai chat uji, server lokal, eval, dan engine saat memuat model. */
    fun effective(p: AiProject): ChatParams {
        val c = p.chat
        val mf = parseModelfile(p.files.modelfile)
        val gc = parseGenerationConfig(p.files.generationConfigJson)
        val eos = p.tokenizer.special.eos?.takeIf { it.isNotBlank() }
        return c.copy(
            systemPrompt = pick(c.systemPrompt, BASE.systemPrompt, mf.system, null),
            temperature = pick(c.temperature, BASE.temperature, mf.temperature, gc.temperature),
            topP = pick(c.topP, BASE.topP, mf.topP, gc.topP),
            topK = pick(c.topK, BASE.topK, mf.topK, gc.topK),
            minP = pick(c.minP, BASE.minP, mf.minP, gc.minP),
            repeatPenalty = pick(c.repeatPenalty, BASE.repeatPenalty, mf.repeatPenalty, gc.repeatPenalty),
            presencePenalty = pick(c.presencePenalty, BASE.presencePenalty, mf.presencePenalty, null),
            frequencyPenalty = pick(c.frequencyPenalty, BASE.frequencyPenalty, mf.frequencyPenalty, null),
            maxTokens = pick(c.maxTokens, BASE.maxTokens, mf.maxTokens, gc.maxTokens),
            seed = pick(c.seed, BASE.seed, mf.seed, null),
            contextLength = pick(c.contextLength, BASE.contextLength, mf.contextLength, null),
            stopSequences = (c.stopSequences + mf.stop + listOfNotNull(eos)).distinct(),
        )
    }
}
