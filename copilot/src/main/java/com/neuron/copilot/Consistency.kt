package com.neuron.copilot

import com.neuron.model.AiProject
import kotlinx.serialization.json.*

/**
 * Pemeriksaan konsistensi model/config.json <-> tokenizer (tokenizer.json + vocab.json).
 * Hanya memeriksa pasangan yang sama-sama terisi; field yang tidak ada dilewati.
 */
object Consistency {
    /** Daftar masalah pada [p]; kosong = konsisten. */
    fun problems(p: AiProject): List<String> {
        val out = ArrayList<String>()
        val cfg = runCatching { Json.parseToJsonElement(p.files.configJson) as? JsonObject }.getOrNull()
        if (cfg == null) {
            out.add("model/config.json harus berupa objek JSON")
            return out
        }
        val vocab: Map<String, Int> = runCatching { Json.decodeFromString<Map<String, Int>>(p.tokenizer.vocabJson) }.getOrNull()
            ?: run { out.add("tokenizer/vocab.json tidak bisa dibaca"); return out }

        val vocabSize = cfg.int("vocab_size")
        val maxId = vocab.values.maxOrNull()
        if (vocabSize != null && maxId != null && maxId >= vocabSize) {
            out.add("ID token tertinggi ($maxId) melebihi vocab_size ($vocabSize) di config.json")
        }
        val sp = p.tokenizer.special
        for ((label, token, cfgKey) in listOf(
            Triple("bos", sp.bos, "bos_token_id"),
            Triple("eos", sp.eos, "eos_token_id"),
            Triple("pad", sp.pad, "pad_token_id"),
            Triple("unk", sp.unk, "unk_token_id"),
        )) {
            if (token.isNullOrEmpty()) continue
            val id = vocab[token]
            if (id == null) {
                out.add("special token $label \"$token\" tidak ada di vocab.json")
                continue
            }
            val cfgId = cfg.int(cfgKey)
            if (cfgId != null && cfgId != id) out.add("$cfgKey di config.json ($cfgId) berbeda dari ID \"$token\" di vocab.json ($id)")
        }
        return out
    }

    /** Masalah yang BARU muncul akibat perubahan (masalah lama tidak memblokir perbaikan). */
    fun introduced(before: AiProject, after: AiProject): List<String> =
        problems(after) - problems(before).toSet()

    private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
}
