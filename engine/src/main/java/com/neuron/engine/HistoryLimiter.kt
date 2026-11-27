package com.neuron.engine

/**
 * Membatasi riwayat chat yang dikirim ke model supaya prompt selalu muat di konteks, dengan pesan terbaru diprioritaskan.
 * Dijalankan di dalam [LlamaCppEngine.chat], jadi berlaku juga untuk Copilot, RAG, dan tool calling.
 * Dua batas: jumlah pesan ([MAX_MESSAGES]) dan perkiraan token dibanding contextLength yang benar-benar dimuat.
 * Tanpa ini native diam-diam membuang bagian tengah prompt; di sini pemangkasan dilaporkan dan pesan tunggal yang
 * terlalu panjang ditolak dengan error CONTEXT yang jelas.
 */
object HistoryLimiter {
    const val MAX_MESSAGES = 16
    private const val CHARS_PER_TOKEN = 3     // konservatif untuk teks Latin; karakter non-ASCII dihitung 1 token
    private const val PER_MESSAGE_OVERHEAD = 8   // token pembungkus role/template per pesan

    class Result(val messages: List<ChatMessage>, val dropped: Int)

    fun estimateTokens(text: String): Int {
        var ascii = 0
        var other = 0
        for (c in text) if (c.code < 128) ascii++ else other++
        return ascii / CHARS_PER_TOKEN + other + 1
    }

    fun limit(
        messages: List<ChatMessage>,
        contextLength: Int,
        maxTokens: Int,
        systemPrompt: String,
        maxMessages: Int = MAX_MESSAGES,
    ): Result {
        if (messages.isEmpty()) return Result(messages, 0)
        // Cadangan jawaban sama dengan aturan di native (neuron_llama.cpp): max(16, min(maxTokens, ctx/4)).
        val reserve = maxOf(16, minOf(maxTokens, contextLength / 4))
        val budget = contextLength - 1 - reserve - estimateTokens(systemPrompt) - PER_MESSAGE_OVERHEAD
        if (budget <= 0) {
            throw EngineException(
                EngineErrorKind.CONTEXT,
                "contextLength $contextLength terlalu kecil untuk system prompt dan jawaban (maxTokens $maxTokens). Naikkan contextLength atau kecilkan maxTokens/system prompt.",
            )
        }
        val kept = ArrayDeque<ChatMessage>()
        var used = 0
        for (m in messages.asReversed()) {
            if (kept.size >= maxMessages) break
            val cost = estimateTokens(m.content) + PER_MESSAGE_OVERHEAD
            if (used + cost > budget) {
                if (kept.isEmpty()) {
                    throw EngineException(
                        EngineErrorKind.CONTEXT,
                        "Pesan terakhir terlalu panjang untuk contextLength $contextLength (perkiraan ${cost} token, batas $budget). Persingkat pesan atau naikkan contextLength.",
                    )
                }
                break
            }
            kept.addFirst(m)
            used += cost
        }
        // Jangan mulai dari balasan asisten tanpa pertanyaannya: beberapa template menolak urutan itu.
        while (kept.size > 1 && kept.first().role == "assistant") kept.removeFirst()
        return Result(kept.toList(), messages.size - kept.size)
    }
}
