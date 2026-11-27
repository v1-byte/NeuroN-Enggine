package com.neuron.model
import kotlinx.serialization.Serializable

enum class TrainMethod { FULL_FINETUNE, LORA, QLORA, DPO, RLHF }
enum class TrainTarget { ON_DEVICE, REMOTE_SERVER }

/** 5. Pelatihan ulang */
@Serializable
data class TrainingConfig(
    val method: TrainMethod = TrainMethod.LORA,
    val target: TrainTarget = TrainTarget.ON_DEVICE,
    val baseModel: String = "Qwen/Qwen2.5-0.5B-Instruct",
    val datasetPath: String = "",
    val learningRate: Double = 2e-4,
    val epochs: Int = 1,
    val batchSize: Int = 2,
    val loraRank: Int = 8,
    val loraAlpha: Int = 16,
    val remoteTrainerUrl: String = "",
    val remoteTrainerApiKey: String = "",
    val valDatasetPath: String = "",   // hasil split (val.jsonl); kosong = tanpa validasi
    val valRatio: Double = 0.1,
    val splitSeed: Long = 42,
    // ON_DEVICE (binary finetune llama.cpp). "native:NAMA" = dari folder native lib app.
    // Argumen & regex di bawah HARUS disesuaikan dengan build llama.cpp yang dipakai (lihat docs/ON_DEVICE.md).
    val onDeviceBinary: String = "native:libllamafinetune.so",
    val onDeviceArgs: String = "--model-base {base} --train-data {train} --lora-out {out} --epochs {epochs} --adam-iter {iters} --lora-r {rank} --lora-alpha {alpha} --threads {threads} --ctx-size {ctx}",
    val onDeviceLossRegex: String = "loss[=: ]+([0-9]+(?:\\.[0-9]+)?)",
    val onDeviceMaxSteps: Int = 300,
)
