package com.neuron.project

/** Parameter di Explorer. [key] = nama field JSON di file tersebut; null = buka file dari awal. */
data class ExplorerParam(val label: String, val key: String? = null)

/** Satu file di Explorer beserta parameter di dalamnya. */
data class ExplorerFile(val path: String, val params: List<ExplorerParam> = emptyList())

/** Satu bagian Explorer, misalnya "1. Parameter Chat". */
data class ExplorerSection(val title: String, val files: List<ExplorerFile>)

/**
 * Pengelompokan Explorer menurut 7 bagian pembuatan AI.
 * Semua file di [VirtualTree.paths] harus tampil tepat satu kali (dijaga oleh ExplorerSectionsTest).
 * File yang belum masuk daftar di sini otomatis masuk ke [OTHER].
 */
object ExplorerSections {
    const val OTHER = "Lainnya"

    private fun p(label: String, key: String? = null) = ExplorerParam(label, key)

    private val sections: List<ExplorerSection> = listOf(
        ExplorerSection("1. Parameter Chat", listOf(
            ExplorerFile("chat/system_prompt.md", listOf(p("System Prompt"))),
            ExplorerFile("chat/params.json", listOf(
                p("Temperature", "temperature"), p("Top-p", "topP"), p("Top-k", "topK"), p("Min-p", "minP"),
                p("Repeat Penalty", "repeatPenalty"), p("Presence Penalty", "presencePenalty"),
                p("Frequency Penalty", "frequencyPenalty"), p("Max Tokens", "maxTokens"), p("Seed", "seed"),
                p("Stop Sequences", "stopSequences"), p("Context Length", "contextLength"),
            )),
        )),
        ExplorerSection("2. File Model", listOf(
            ExplorerFile("model/Modelfile", listOf(p("Modelfile"))),
            ExplorerFile("model/quantization.json", listOf(
                p("Quantization", "quantization"),
                p("Format Model (GGUF, Safetensors, ONNX, AWQ, GPTQ)", "format"),
            )),
            ExplorerFile("model/chat_template.jinja", listOf(p("Chat Template"))),
            ExplorerFile("model/config.json", listOf(p("config.json"))),
            ExplorerFile("model/generation_config.json", listOf(p("generation_config.json"))),
            ExplorerFile("model/ops.json", listOf(p("Operasi model: konversi, quantize, merge"))),
        )),
        ExplorerSection("3. Tokenizer", listOf(
            ExplorerFile("tokenizer/vocab.json", listOf(p("Vocab"))),
            ExplorerFile("tokenizer/tokenizer.json", listOf(p("Special Tokens", "special"))),
        )),
        ExplorerSection("4. Pengetahuan Tambahan", listOf(
            ExplorerFile("knowledge/rag.json", listOf(
                p("RAG", "ragEnabled"),
                p("Vector Database", "vectorDb"),
                p("Embedding Model", "embeddingModelPath"),
                p("Knowledge File", "knowledgeFiles"),
            )),
        )),
        ExplorerSection("5. Pelatihan Ulang", listOf(
            ExplorerFile("training/train.json", listOf(
                p("Fine-tuning", "method"), p("LoRA / QLoRA", "method"), p("DPO / RLHF", "method"),
                p("Dataset", "datasetPath"), p("Learning Rate", "learningRate"), p("Epoch", "epochs"),
                p("Batch Size", "batchSize"), p("LoRA Rank", "loraRank"), p("LoRA Alpha", "loraAlpha"),
            )),
            ExplorerFile("model/lora.json", listOf(p("Adapter LoRA"))),
        )),
        ExplorerSection("6. Mesin / Hardware", listOf(
            ExplorerFile("hardware/engine.json", listOf(
                p("Num GPU Layers", "numGpuLayers"), p("Threads", "threads"),
                p("Batch Size Inference", "batchSizeInference"), p("KV Cache", "kvCacheType"),
                p("Flash Attention", "flashAttention"), p("RoPE Scaling", "ropeScalingType"),
                p("Logit Bias", "logitBias"),
            )),
            ExplorerFile("engine/api.json", listOf(p("Mesin: lokal atau API"))),
        )),
        ExplorerSection("7. Fitur", listOf(
            ExplorerFile("features/features.json", listOf(
                p("Tools / Function Calling", "tools"), p("Vision", "visionEnabled"),
                p("Voice / TTS / STT", "ttsEnabled"), p("Guardrails / Filter", "guardrailBlockedWords"),
            )),
        )),
        ExplorerSection(OTHER, listOf(
            ExplorerFile("eval/cases.json", listOf(p("Kasus evaluasi"))),
        )),
    )

    /**
     * Bagian untuk ditampilkan. Hanya path yang ada di [VirtualTree.paths] yang dipakai,
     * dan path yang belum terdaftar di sini dimasukkan ke bagian [OTHER].
     */
    fun groups(): List<ExplorerSection> {
        val known = VirtualTree.paths.toSet()
        val listed = sections.flatMap { s -> s.files.map { it.path } }.toSet()
        val rest = VirtualTree.paths.filter { it !in listed }.map { ExplorerFile(it) }
        return sections.map { s ->
            val kept = s.files.filter { it.path in known }
            s.copy(files = if (s.title == OTHER) kept + rest else kept)
        }.filter { it.files.isNotEmpty() }
    }
}
