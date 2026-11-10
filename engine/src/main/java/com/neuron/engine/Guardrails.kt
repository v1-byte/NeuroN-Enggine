package com.neuron.engine

import com.neuron.model.FeatureConfig
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

private class GuardAbort : RuntimeException()

/**
 * Guardrail kata terlarang + regex (tanpa membedakan huruf besar/kecil). Input dicek sebelum model dipanggil.
 * Output dicek saat streaming dengan menahan ekor `window` karakter, jadi kata yang terbelah antar-token tetap tertangkap
 * sebelum sempat tampil. Pola regex yang lebih panjang dari window bisa sebagian sudah tampil sebelum terdeteksi.
 */
class Guardrails(cfg: FeatureConfig) {
    companion object {
        const val BLOCKED_INPUT = "[Pesan diblokir oleh guardrail]"
        const val BLOCKED_OUTPUT = "\n[Output dihentikan oleh guardrail]"
    }
    private val words = cfg.guardrailBlockedWords.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
    private val regexes = cfg.guardrailRegex.mapNotNull { runCatching { Regex(it, RegexOption.IGNORE_CASE) }.getOrNull() }
    val active: Boolean get() = words.isNotEmpty() || regexes.isNotEmpty()
    private val window = maxOf(64, words.maxOfOrNull { it.length } ?: 0)

    fun matches(text: String): Boolean {
        val t = text.lowercase()
        return words.any { t.contains(it) } || regexes.any { it.containsMatchIn(text) }
    }

    /** Pesan penolakan bila `text` melanggar, atau null bila aman. */
    fun checkInput(text: String): String? = if (active && matches(text)) BLOCKED_INPUT else null

    fun filter(src: Flow<String>): Flow<String> = if (!active) src else flow {
        val recent = StringBuilder()    // jendela untuk pemeriksaan
        val pending = StringBuilder()   // belum ditampilkan
        try {
            src.collect { tok ->
                pending.append(tok); recent.append(tok)
                if (recent.length > 2048) recent.delete(0, recent.length - 1024)
                if (matches(recent.toString())) throw GuardAbort()
                if (pending.length > window) {
                    val n = pending.length - window
                    emit(pending.substring(0, n)); pending.delete(0, n)
                }
            }
            emit(pending.toString())
        } catch (e: GuardAbort) {
            emit(BLOCKED_OUTPUT)
        }
    }
}

class GuardedEngine(private val inner: InferenceEngine, private val g: Guardrails, private val checkInput: Boolean) : InferenceEngine by inner {
    override fun chat(messages: List<ChatMessage>, params: ChatParams): Flow<String> = flow {
        if (checkInput) {
            val last = messages.lastOrNull { it.role == "user" }
            val refusal = last?.let { g.checkInput(it.content) }
            if (refusal != null) { emit(refusal); return@flow }
        }
        g.filter(inner.chat(messages, params)).collect { emit(it) }
    }
}
