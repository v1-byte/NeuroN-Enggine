package com.neuron.engine

import com.neuron.model.AiProject
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.sync.withLock

/** Ringkasan satu prompt benchmark. Token/detik hanya tersedia bila engine melaporkan token count. */
data class EngineBenchmarkSample(
    val prompt: String,
    val elapsedMillis: Long,
    val timeToFirstTokenMillis: Long?,
    val outputCharacters: Int,
    val outputPreview: String,
    val completionTokens: Int?,
    val tokensPerSecond: Double?,
)

/**
 * Benchmark serial memakai gerbang engine yang sama dengan chat/server agar native llama.cpp tidak
 * menerima generate paralel. Prompt tetap dan sampling deterministik membuat perbandingan lebih berguna.
 */
class EngineBenchmarkRunner(private val engine: InferenceEngine) {
    suspend fun run(
        project: AiProject,
        prompts: List<String> = DEFAULT_PROMPTS,
        maxTokens: Int = DEFAULT_MAX_TOKENS,
    ): List<EngineBenchmarkSample> {
        require(prompts.isNotEmpty()) { "Benchmark memerlukan sedikitnya satu prompt." }
        require(prompts.none { it.isBlank() }) { "Prompt benchmark tidak boleh kosong." }
        require(maxTokens in 1..512) { "maxTokens harus berada pada rentang 1–512." }
        val params = ModelDefaults.effective(project).copy(
            temperature = 0f,
            topP = 1f,
            seed = 42,
            maxTokens = maxTokens,
        )
        return prompts.map { prompt ->
            val started = System.nanoTime()
            var firstTokenAt: Long? = null
            var stats: GenStats? = null
            val output = EngineHub.gate.withLock {
                val text = StringBuilder()
                engine.chat(listOf(ChatMessage("user", prompt)), params).collect { chunk ->
                    if (firstTokenAt == null) firstTokenAt = System.nanoTime()
                    text.append(chunk)
                }
                stats = engine.lastStats
                text.toString()
            }
            val elapsed = ((System.nanoTime() - started) / 1_000_000L).coerceAtLeast(1L)
            val resultStats = stats
            EngineBenchmarkSample(
                prompt = prompt,
                elapsedMillis = elapsed,
                timeToFirstTokenMillis = firstTokenAt?.let {
                    ((it - started) / 1_000_000L).coerceAtLeast(0L)
                },
                outputCharacters = output.length,
                outputPreview = output.take(MAX_PREVIEW_CHARS),
                completionTokens = resultStats?.completionTokens?.takeIf { it > 0 },
                tokensPerSecond = resultStats?.tokensPerSecond?.takeIf { it > 0.0 },
            )
        }
    }

    companion object {
        const val DEFAULT_MAX_TOKENS = 64
        private const val MAX_PREVIEW_CHARS = 160
        val DEFAULT_PROMPTS = listOf(
            "Balas tepat: OK",
            "Sebutkan tiga warna primer.",
            "Berapa 7 dikali 8? Jawab singkat.",
        )
    }
}
