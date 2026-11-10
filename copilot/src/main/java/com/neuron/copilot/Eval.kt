package com.neuron.copilot

import com.neuron.engine.ChatMessage
import com.neuron.engine.EngineHub
import com.neuron.engine.InferenceEngine
import com.neuron.engine.ModelDefaults
import com.neuron.model.AiProject
import com.neuron.model.EvalCase
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.sync.withLock

data class EvalResult(
    val name: String,
    val output: String,
    val passed: Boolean,
    val missing: List<String>,
    val forbidden: List<String>,
)

enum class Verdict { IMPROVED, REGRESSED, STILL_PASS, STILL_FAIL }

/**
 * Menjalankan kasus eval dengan parameter deterministik (temperature 0, seed tetap)
 * supaya hasil sebelum dan sesudah perubahan bisa dibandingkan.
 * Penilaian: kata wajib (mustContain) harus ada, kata terlarang (mustNotContain) tidak boleh ada.
 */
class EvalRunner(private val engine: InferenceEngine) {

    suspend fun run(project: AiProject): List<EvalResult> {
        val ev = project.eval
        val params = ModelDefaults.effective(project).copy(temperature = 0f, topP = 1f, seed = 42, maxTokens = ev.maxTokens)
        return ev.cases.mapIndexed { i, c ->
            val out = EngineHub.gate.withLock {
                engine.chat(listOf(ChatMessage("user", c.prompt)), params).toList().joinToString("")
            }
            score(c.name.ifBlank { "kasus ${i + 1}" }, c, out)
        }
    }

    companion object {
        fun score(name: String, c: EvalCase, output: String): EvalResult {
            val low = output.lowercase()
            val missing = c.mustContain.filter { it.isNotBlank() && !low.contains(it.lowercase()) }
            val forbidden = c.mustNotContain.filter { it.isNotBlank() && low.contains(it.lowercase()) }
            val passed = output.isNotBlank() && missing.isEmpty() && forbidden.isEmpty()
            return EvalResult(name, output, passed, missing, forbidden)
        }

        /** Bandingkan dua putaran eval berdasarkan urutan kasus yang sama. */
        fun compare(before: List<EvalResult>, after: List<EvalResult>): List<Pair<String, Verdict>> =
            before.zip(after).map { (b, a) ->
                a.name to when {
                    !b.passed && a.passed -> Verdict.IMPROVED
                    b.passed && !a.passed -> Verdict.REGRESSED
                    a.passed -> Verdict.STILL_PASS
                    else -> Verdict.STILL_FAIL
                }
            }
    }
}
