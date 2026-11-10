package com.neuron.model
import kotlinx.serialization.Serializable

enum class ModelFormat { GGUF, SAFETENSORS, ONNX, AWQ, GPTQ }

/** 2. File Model. Hanya GGUF & ONNX yang bisa dijalankan langsung di HP; sisanya perlu konversi (lihat docs). */
@Serializable
data class ModelFiles(
    val modelPath: String = "",
    val format: ModelFormat = ModelFormat.GGUF,
    val quantization: String = "Q4_K_M",
    val modelfile: String = "",             // teks Modelfile (FROM/PARAMETER/TEMPLATE/SYSTEM)
    val chatTemplate: String = "",          // Jinja / template teks
    val configJson: String = "{}",
    val generationConfigJson: String = "{}",
    val loraPath: String = "",              // adapter LoRA berformat GGUF (hasil training/konversi)
    val loraScale: Float = 1f,
)

/** Tampilan ringkas untuk tab model/quantization.json */
@Serializable
data class QuantInfo(val modelPath: String = "", val format: ModelFormat = ModelFormat.GGUF, val quantization: String = "Q4_K_M")

/** Tampilan tab model/lora.json */
@Serializable
data class LoraInfo(val path: String = "", val scale: Float = 1f)

/** Format yang bisa dijalankan langsung di HP (engine lokal). Selain GGUF harus dikonversi dulu. */
fun ModelFormat.runnableOnDevice(): Boolean = this == ModelFormat.GGUF

/** Langkah yang disarankan untuk format ini, ditampilkan saat engine lokal menolak. */
fun ModelFormat.conversionHint(): String = when (this) {
    ModelFormat.GGUF -> "Sudah GGUF."
    ModelFormat.SAFETENSORS -> "Konversi ke GGUF lewat Operasi model (CONVERT_TO_GGUF) di server."
    ModelFormat.AWQ, ModelFormat.GPTQ -> "Unduh versi FP16/BF16 (safetensors) dari repo asalnya, lalu konversi ke GGUF di server."
    ModelFormat.ONNX -> "ONNX belum didukung: butuh runtime onnxruntime-genai."
}
