package com.neuron.model
import kotlinx.serialization.Serializable

enum class ModelOp { DOWNLOAD_HF, CONVERT_TO_GGUF, QUANTIZE, MERGE_LORA, MERGE_LORA_GGUF, MERGE_MODELS, INSPECT, SET_GGUF_META }

/** Operasi edit model (dijalankan di server Python/llama.cpp; ukuran model dibatasi RAM/disk server saja). */
@Serializable
data class ModelOpsConfig(
    val serverUrl: String = "",          // kosong = pakai training.remoteTrainerUrl
    val serverApiKey: String = "",
    val op: ModelOp = ModelOp.INSPECT,
    val source: String = "",             // nama model di server / id repo HF / job id adapter
    val output: String = "",
    val quantization: String = "Q4_K_M", // QUANTIZE
    val allowRequantize: Boolean = false, // QUANTIZE: izinkan sumber yang sudah terkuantisasi (kualitas turun)
    val outtype: String = "f16",         // CONVERT_TO_GGUF: f16 | bf16 | q8_0
    val adapter: String = "",            // MERGE_LORA (job id/folder PEFT) | MERGE_LORA_GGUF (adapter .gguf)
    val loraScale: Double = 1.0,         // MERGE_LORA_GGUF, 0..4
    val mergeSources: List<String> = emptyList(),   // MERGE_MODELS (arsitektur harus sama)
    val mergeWeights: List<Double> = emptyList(),
    val metaKey: String = "",            // SET_GGUF_META, mis. tokenizer.chat_template
    val metaValue: String = "",
)
