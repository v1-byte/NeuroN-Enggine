package com.neuron.project

import com.neuron.model.*
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Peta "klik bagian -> tampil kode". Satu path = satu tab editor.
 * read()  : AiProject -> teks yang tampil di editor
 * write() : teks editor -> AiProject baru (parse + validasi). Gagal = Result.failure(pesan error)
 */
object VirtualTree {
    val json = Json { prettyPrint = true; ignoreUnknownKeys = true; encodeDefaults = true }

    /** Urutan = urutan di Explorer. Awalan folder dipakai sebagai grup. */
    val paths = listOf(
        "engine/api.json",
        "chat/params.json", "chat/system_prompt.md",
        "model/Modelfile", "model/chat_template.jinja", "model/config.json",
        "model/generation_config.json", "model/quantization.json", "model/lora.json", "model/ops.json",
        "tokenizer/tokenizer.json", "tokenizer/vocab.json",
        "knowledge/rag.json",
        "training/train.json",
        "hardware/engine.json",
        "features/features.json", "eval/cases.json",
    )

    fun read(p: AiProject, path: String): String = when (path) {
        "engine/api.json" -> json.encodeToString(p.engine)
        "chat/params.json" -> json.encodeToString(p.chat)
        "chat/system_prompt.md" -> p.chat.systemPrompt
        "model/Modelfile" -> p.files.modelfile
        "model/chat_template.jinja" -> p.files.chatTemplate
        "model/config.json" -> p.files.configJson
        "model/generation_config.json" -> p.files.generationConfigJson
        "model/quantization.json" -> json.encodeToString(QuantInfo(p.files.modelPath, p.files.format, p.files.quantization))
        "model/lora.json" -> json.encodeToString(LoraInfo(p.files.loraPath, p.files.loraScale))
        "model/ops.json" -> json.encodeToString(p.ops)
        "tokenizer/tokenizer.json" -> json.encodeToString(p.tokenizer)
        "tokenizer/vocab.json" -> p.tokenizer.vocabJson
        "knowledge/rag.json" -> json.encodeToString(p.knowledge)
        "training/train.json" -> json.encodeToString(p.training)
        "hardware/engine.json" -> json.encodeToString(p.hardware)
        "features/features.json" -> json.encodeToString(p.features)
        "eval/cases.json" -> json.encodeToString(p.eval)
        else -> "// path tidak dikenal: $path"
    }

    fun write(p: AiProject, path: String, text: String): Result<AiProject> = runCatching {
        when (path) {
            "engine/api.json" -> p.copy(engine = json.decodeFromString<EngineConfig>(text))
            "chat/params.json" -> json.decodeFromString<ChatParams>(text).also { it.validate() }.let { p.copy(chat = it) }
            "chat/system_prompt.md" -> p.copy(chat = p.chat.copy(systemPrompt = text))
            "model/Modelfile" -> p.copy(files = p.files.copy(modelfile = text))
            "model/chat_template.jinja" -> p.copy(files = p.files.copy(chatTemplate = text))
            "model/config.json" -> { json.parseToJsonElement(text); p.copy(files = p.files.copy(configJson = text)) }
            "model/generation_config.json" -> { json.parseToJsonElement(text); p.copy(files = p.files.copy(generationConfigJson = text)) }
            "model/quantization.json" -> json.decodeFromString<QuantInfo>(text).let {
                p.copy(files = p.files.copy(modelPath = it.modelPath, format = it.format, quantization = it.quantization))
            }
            "model/lora.json" -> json.decodeFromString<LoraInfo>(text).let { p.copy(files = p.files.copy(loraPath = it.path, loraScale = it.scale)) }
            "model/ops.json" -> json.decodeFromString<ModelOpsConfig>(text).also { it.validate() }.let { p.copy(ops = it) }
            "tokenizer/tokenizer.json" -> p.copy(tokenizer = json.decodeFromString<TokenizerConfig>(text))
            "tokenizer/vocab.json" -> json.decodeFromString<Map<String, Int>>(text).let { m ->
                require(m.values.all { it >= 0 }) { "ID token tidak boleh negatif" }
                require(m.values.toSet().size == m.size) { "ID token tidak boleh ganda" }
                p.copy(tokenizer = p.tokenizer.copy(vocabJson = text))
            }
            "knowledge/rag.json" -> json.decodeFromString<KnowledgeConfig>(text).also { it.validate() }.let { p.copy(knowledge = it) }
            "training/train.json" -> json.decodeFromString<TrainingConfig>(text).also { it.validate() }.let { p.copy(training = it) }
            "hardware/engine.json" -> json.decodeFromString<HardwareConfig>(text).also { it.validate() }.let { p.copy(hardware = it) }
            "features/features.json" -> json.decodeFromString<FeatureConfig>(text).also { it.validate() }.let { p.copy(features = it) }
            "eval/cases.json" -> json.decodeFromString<EvalConfig>(text).also { it.validate() }.let { p.copy(eval = it) }
            else -> error("path tidak dikenal: $path")
        }
    }.recoverCatching { throw IllegalArgumentException(it.message?.lineSequence()?.firstOrNull() ?: "Format tidak valid") }
}
