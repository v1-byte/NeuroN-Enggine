package com.neuron.model
import kotlinx.serialization.Serializable

/** 6. Mesin / Hardware */
@Serializable
data class HardwareConfig(
    val numGpuLayers: Int = 0,
    val threads: Int = 4,
    val batchSizeInference: Int = 512,
    val kvCacheType: String = "f16",       // f16 | q8_0 | q4_0
    val flashAttention: Boolean = false,
    val ropeScalingType: String = "none",  // none | linear | yarn
    val ropeFreqScale: Float = 1f,
    val logitBias: Map<Int, Float> = emptyMap(),
)
