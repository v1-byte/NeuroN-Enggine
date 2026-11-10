package com.neuron.model

/** Dilempar sebagai IllegalArgumentException dengan pesan Indonesia; ditampilkan di editor. */
fun ChatParams.validate() {
    require(temperature in 0f..5f) { "temperature harus 0..5" }
    require(topP in 0f..1f) { "topP harus 0..1" }
    require(topK >= 0) { "topK tidak boleh negatif" }
    require(minP in 0f..1f) { "minP harus 0..1" }
    require(repeatPenalty > 0f) { "repeatPenalty harus > 0" }
    require(presencePenalty in -2f..2f) { "presencePenalty harus -2..2" }
    require(frequencyPenalty in -2f..2f) { "frequencyPenalty harus -2..2" }
    require(maxTokens > 0) { "maxTokens harus > 0" }
    require(contextLength >= 128) { "contextLength minimal 128" }
}
fun HardwareConfig.validate() {
    require(threads >= 1) { "threads minimal 1" }
    require(batchSizeInference >= 1) { "batchSizeInference minimal 1" }
    require(numGpuLayers >= 0) { "numGpuLayers tidak boleh negatif" }
    require(kvCacheType in listOf("f16", "q8_0", "q4_0")) { "kvCacheType: f16 | q8_0 | q4_0" }
    require(kvCacheType == "f16" || flashAttention) { "kvCacheType selain f16 butuh flashAttention=true" }
    require(ropeScalingType in listOf("none", "linear", "yarn")) { "ropeScalingType: none | linear | yarn" }
    require(ropeFreqScale > 0f) { "ropeFreqScale harus > 0" }
}
fun TrainingConfig.validate() {
    require(learningRate > 0) { "learningRate harus > 0" }
    require(epochs >= 1 && batchSize >= 1) { "epochs & batchSize minimal 1" }
    require(loraRank >= 1 && loraAlpha >= 1) { "loraRank & loraAlpha minimal 1" }
    require(valRatio in 0.0..0.5) { "valRatio harus 0..0.5" }
    require(onDeviceMaxSteps in 1..5000) { "onDeviceMaxSteps harus 1..5000" }
    require(runCatching { Regex(onDeviceLossRegex) }.isSuccess) { "onDeviceLossRegex tidak valid" }
}
fun KnowledgeConfig.validate() {
    require(vectorDb in listOf("sqlite", "memory")) { "vectorDb: sqlite | memory" }
    require(chunkSize >= 64) { "chunkSize minimal 64" }
    require(chunkOverlap in 0 until chunkSize) { "chunkOverlap harus < chunkSize" }
    require(topK >= 1) { "topK minimal 1" }
    require(minScore in 0f..1f) { "minScore harus 0..1" }
}
fun ModelOpsConfig.validate() {
    when (op) {
        ModelOp.INSPECT -> require(source.isNotBlank()) { "source wajib" }
        ModelOp.DOWNLOAD_HF -> require(source.isNotBlank()) { "source (id repo HF) wajib" }
        ModelOp.CONVERT_TO_GGUF -> require(source.isNotBlank() && output.endsWith(".gguf")) { "source wajib, output harus berakhiran .gguf" }
        ModelOp.QUANTIZE -> require(source.isNotBlank() && output.endsWith(".gguf") && quantization.isNotBlank()) { "source, quantization wajib; output .gguf" }
        ModelOp.MERGE_LORA -> require(source.isNotBlank() && adapter.isNotBlank() && output.isNotBlank()) { "source, adapter, output wajib" }
        ModelOp.MERGE_MODELS -> {
            require(mergeSources.size >= 2 && output.isNotBlank()) { "minimal 2 mergeSources dan output" }
            require(mergeWeights.isEmpty() || mergeWeights.size == mergeSources.size) { "mergeWeights harus sama jumlahnya dengan mergeSources" }
        }
        ModelOp.SET_GGUF_META -> require(source.isNotBlank() && output.endsWith(".gguf") && metaKey.isNotBlank()) { "source, output(.gguf), metaKey wajib" }
    }
}
fun FeatureConfig.validate() {
    guardrailRegex.forEach { r -> runCatching { Regex(r) }.onFailure { throw IllegalArgumentException("Regex tidak valid: $r") } }
    require(tools.map { it.name }.toSet().size == tools.size) { "Nama tool harus unik" }
    tools.forEach { require(it.name.matches(Regex("[A-Za-z0-9_-]{1,64}"))) { "Nama tool '${it.name}' hanya boleh huruf/angka/_/-" } }
}
