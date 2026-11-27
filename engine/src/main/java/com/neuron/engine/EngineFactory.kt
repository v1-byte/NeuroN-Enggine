package com.neuron.engine

import com.neuron.model.*

object EngineFactory {
    fun create(p: AiProject): InferenceEngine {
        require(p.files.format.runnableOnDevice()) {
            "Format ${p.files.format} tidak bisa dijalankan di HP. ${p.files.format.conversionHint()}"
        }
        return LlamaCppEngine()   // butuh build native (-PwithNative), lihat docs
    }
    /**
     * Kunci cache: engine dibuat ulang hanya jika bagian ini berubah.
     * Adapter LoRA (path/skala) sengaja TIDAK ikut: pergantiannya cukup lewat [LoraCapable.setLora] tanpa memuat ulang model.
     */
    fun key(p: AiProject) = listOf(p.engine, p.files.modelPath, p.files.chatTemplate, p.hardware, ModelDefaults.effective(p).contextLength).joinToString("|")

    /**
     * Membungkus engine dengan fitur dari features/features.json: tool calling (bila ada tools) lalu guardrail.
     * `checkInput=false` jika pemanggil sudah memeriksa teks asli pengguna (mis. sebelum konteks RAG disisipkan).
     */
    fun wrap(engine: InferenceEngine, p: AiProject, checkInput: Boolean = true, exec: ToolExecutor = BuiltinTools): InferenceEngine {
        var e = engine
        if (p.features.tools.isNotEmpty()) e = ToolEngine(e, p.features.tools, exec)
        val g = Guardrails(p.features)
        if (g.active) e = GuardedEngine(e, g, checkInput)
        return e
    }
}
