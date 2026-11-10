package com.neuron.model
import kotlinx.serialization.Serializable

enum class ModelOp { DOWNLOAD_HF, CONVERT_TO_GGUF, QUANTIZE, MERGE_LORA, MERGE_MODELS, INSPECT, SET_GGUF_META }

/** Operasi edit model (dijalankan di server Python/llama.cpp; ukuran model dibatasi RAM/disk server saja). */
@Serializable
data class ModelOpsConfig(
    val serverUrl: String = "",          // kosong = pakai training.remoteTrainerUrl
    val serverApiKey: String = "",
    val op: ModelOp = ModelOp.INSPECT,
    val source: String = "",             // nama model di server / id repo HF / job id adapter
    val output: String = "",
    val quantization: String = "Q4_K_M", // QUANTIZE
    val outtype: String = "f16",         // CONVERT_TO_GGUF: f16 | bf16 | q8_0
    val adapter: String = "",            // MERGE_LORA
    val mergeSources: List<String> = emptyList(),   // MERGE_MODELS (arsitektur harus sama)
    val mergeWeights: List<Double> = emptyList(),
    val metaKey: String = "",            // SET_GGUF_META, mis. tokenizer.chat_template
    val metaValue: String = "",
)
