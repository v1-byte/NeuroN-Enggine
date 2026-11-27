package com.neuron.model
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * Hanya mesin lokal (llama.cpp). Mode API dihapus. project.json lama yang bernilai "API" tetap terbaca
 * dan dianggap LOCAL, jadi proyek lama tidak dibuang sebagai rusak.
 */
@Serializable(with = EngineModeSerializer::class)
enum class EngineMode { LOCAL }

object EngineModeSerializer : KSerializer<EngineMode> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("EngineMode", PrimitiveKind.STRING)
    override fun deserialize(decoder: Decoder): EngineMode {
        decoder.decodeString()   // nilai lama ("API") diabaikan
        return EngineMode.LOCAL
    }
    override fun serialize(encoder: Encoder, value: EngineMode) = encoder.encodeString(value.name)
}

/** Mesin yang menjalankan AI: selalu lokal. Kunci lama (baseUrl, apiKey, model) diabaikan saat dibaca. */
@Serializable
data class EngineConfig(
    val mode: EngineMode = EngineMode.LOCAL,
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
