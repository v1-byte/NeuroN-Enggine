package com.neuron.model
import kotlinx.serialization.Serializable

enum class EngineMode { LOCAL, API }

/** Pilihan mesin yang menjalankan AI: lokal (llama.cpp) atau API OpenAI-compatible. */
@Serializable
data class EngineConfig(
    val mode: EngineMode = EngineMode.API,
    val baseUrl: String = "https://api.openai.com",   // Ollama: http://IP:11434 | llama-server: http://IP:8080
    val apiKey: String = "",
    val model: String = "gpt-4o-mini",
)

@Serializable
data class AiProject(
    val name: String,
    val engine: EngineConfig = EngineConfig(),
    val chat: ChatParams = ChatParams(),
    val files: ModelFiles = ModelFiles(),
    val ops: ModelOpsConfig = ModelOpsConfig(),
    val tokenizer: TokenizerConfig = TokenizerConfig(),
    val knowledge: KnowledgeConfig = KnowledgeConfig(),
    val training: TrainingConfig = TrainingConfig(),
    val hardware: HardwareConfig = HardwareConfig(),
    val features: FeatureConfig = FeatureConfig(),
    val eval: EvalConfig = EvalConfig(),
)
