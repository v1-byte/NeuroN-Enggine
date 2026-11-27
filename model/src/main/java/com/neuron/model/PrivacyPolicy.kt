package com.neuron.model

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Hasil membaca privacy.json: kata dan regex untuk guardrail, plus peringatan untuk ditampilkan ke pengguna. */
data class PrivacyExtract(val words: List<String>, val regex: List<String>, val warnings: List<String>)

/**
 * Privasi Froged_N1: `privacy.json` di repo Hugging Face adalah sumber aturan privasi.
 * Skema file itu belum dikunci, jadi pembacaan dibuat toleran: dokumen dijelajahi dan string dalam array
 * dikenali dari NAMA KUNCI-nya (mis. blocked_terms, forbidden_words, regex, patterns).
 * Hasil selalu ditampilkan ke pengguna sebelum dipakai, jadi salah tangkap bisa dikoreksi di editor.
 */
object PrivacyPolicy {
    const val REPO = "bytecode66/Froged_N1"
    const val FILE = "privacy.json"
    const val MAX_BYTES = 2_000_000
    private const val MAX_ITEMS = 5000
    private const val MAX_LEN = 500

    private val regexKeys = listOf("regex", "pattern", "pola")
    private val wordKeys = listOf("block", "deny", "forbid", "terlarang", "blokir", "term", "word", "kata", "istilah", "keyword", "sensitive", "redact", "phrase")
    private val itemWordKeys = setOf("term", "word", "kata", "istilah", "phrase", "keyword", "value", "text")
    private val ruleKeys = regexKeys + wordKeys + listOf("rule", "aturan", "entit", "pii")

    /**
     * Kunci dokumentasi: isinya tidak pernah dibaca sebagai aturan, walau berada di dalam blok aturan
     * (mis. "description": ["..."] atau "examples": [...] tidak boleh ikut menjadi kata terlarang).
     */
    private val ignoredKeys = listOf("description", "comment", "example", "note", "metadata", "schema", "changelog")

    /** Skema yang didokumentasikan (docs/PRIVACY.md). Pembaca tetap toleran terhadap skema lain. */
    val DOCUMENTED_SCHEMA = """{"version":1,"blocked_terms":["kata"],"regex":["pola"]}"""

    private class Acc {
        val words = LinkedHashSet<String>()
        val regex = LinkedHashSet<String>()
        val warnings = mutableListOf<String>()
    }

    private fun hasAny(key: String, parts: List<String>) = parts.any { key.contains(it) }

    /** Melempar IllegalArgumentException bila bukan JSON yang valid atau terlalu besar. */
    fun parse(text: String): PrivacyExtract {
        require(text.isNotBlank()) { "privacy.json kosong" }
        require(text.length <= MAX_BYTES) { "privacy.json terlalu besar (maks ${MAX_BYTES / 1000} KB)" }
        val root: JsonElement = try {
            Json.parseToJsonElement(text)
        } catch (e: SerializationException) {
            throw IllegalArgumentException("privacy.json bukan JSON yang valid: ${e.message?.lineSequence()?.firstOrNull() ?: "format salah"}")
        }
        val acc = Acc()
        walk(root, "", false, false, acc)

        val validRegex = mutableListOf<String>()
        var invalid = 0
        for (r in acc.regex) {
            if (runCatching { Regex(r) }.isSuccess) validRegex += r else invalid++
        }
        if (invalid > 0) acc.warnings += "$invalid pola regex dilewati karena tidak valid."
        if (acc.words.isEmpty() && validRegex.isEmpty()) {
            acc.warnings += "Tidak ada kata atau regex yang dikenali. Pakai kunci seperti blocked_terms, forbidden_words, regex, atau patterns."
        }
        return PrivacyExtract(acc.words.take(MAX_ITEMS), validRegex.take(MAX_ITEMS), acc.warnings)
    }

    private fun walk(el: JsonElement, key: String, ctx: Boolean, inArray: Boolean, acc: Acc) {
        when (el) {
            is JsonObject -> {
                val here = ctx || hasAny(key, ruleKeys)
                el.forEach { (k, v) ->
                    val lk = k.lowercase()
                    if (!hasAny(lk, ignoredKeys)) walk(v, lk, here, false, acc)
                }
            }
            is JsonArray -> {
                val here = ctx || hasAny(key, ruleKeys)
                el.forEach { walk(it, key, here, true, acc) }
            }
            is JsonPrimitive -> if (el.isString) classify(el.content, key, ctx, inArray, acc)
        }
    }

    private fun classify(raw: String, key: String, ctx: Boolean, inArray: Boolean, acc: Acc) {
        val v = raw.trim()
        if (v.isEmpty()) return
        val isRegexKey = hasAny(key, regexKeys)
        val isWord = (inArray && hasAny(key, wordKeys)) || (ctx && key in itemWordKeys)
        if (!isRegexKey && !isWord) return
        if (v.length > MAX_LEN) {
            acc.warnings += "Satu entri dilewati karena lebih dari $MAX_LEN karakter."
            return
        }
        if (isRegexKey) acc.regex += v else acc.words += v
    }

    /** Gabungkan daftar lama dan baru tanpa duplikat (urutan lama dipertahankan). */
    fun merge(old: List<String>, new: List<String>): List<String> =
        LinkedHashSet<String>().apply { addAll(old); addAll(new) }.toList()
}
