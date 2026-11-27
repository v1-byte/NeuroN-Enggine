package com.neuron.model
import kotlinx.serialization.Serializable

/** 7. Fitur */
@Serializable
data class ToolDef(val name: String, val description: String, val parametersJsonSchema: String)
@Serializable
data class FeatureConfig(
    val tools: List<ToolDef> = emptyList(),
    val visionEnabled: Boolean = false,
    val mmprojPath: String = "",
    val ttsEnabled: Boolean = false,
    val sttEnabled: Boolean = false,
    val voiceLanguage: String = "id",   // BCP-47 untuk TTS & STT, mis. "id-ID" atau "en-US"
    val guardrailRegex: List<String> = emptyList(),     // blokir output/input yang cocok
    val guardrailBlockedWords: List<String> = emptyList(),
)
