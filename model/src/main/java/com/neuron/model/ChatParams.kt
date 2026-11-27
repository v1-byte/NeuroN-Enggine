package com.neuron.model
import kotlinx.serialization.Serializable

/** 1. Parameter Chat -> file virtual: chat/params.json */
@Serializable
data class ChatParams(
    val systemPrompt: String = "You are a helpful assistant.",
    val temperature: Float = 0.8f,
    val topP: Float = 0.95f,
    val topK: Int = 40,
    val minP: Float = 0.05f,
    val repeatPenalty: Float = 1.1f,
    val presencePenalty: Float = 0f,
    val frequencyPenalty: Float = 0f,
    val maxTokens: Int = 512,
    val seed: Long = -1,
    val stopSequences: List<String> = emptyList(),
    val contextLength: Int = 4096,
)
