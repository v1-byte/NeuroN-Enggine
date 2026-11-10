package com.neuron.engine

import com.neuron.model.*
import kotlinx.coroutines.flow.Flow

data class ChatMessage(val role: String, val content: String, val images: List<String> = emptyList())  // images: data URL (vision, mode API)

/**
 * Statistik generate terakhir. `promptTokens` = 0 bila engine tidak melaporkannya (llama.cpp lokal saat ini hanya
 * menghitung token yang dihasilkan). `millis` = waktu dari permintaan dikirim sampai stream selesai.
 */
data class GenStats(val promptTokens: Int = 0, val completionTokens: Int = 0, val millis: Long = 0) {
    val tokensPerSecond: Double get() = if (millis > 0) completionTokens * 1000.0 / millis else 0.0
}

/** Kontrak tunggal. UI, server lokal, RAG, dan Copilot hanya bicara lewat interface ini. */
interface InferenceEngine {
    suspend fun load(project: AiProject)
    fun chat(messages: List<ChatMessage>, params: ChatParams): Flow<String>   // stream token
    suspend fun embed(text: String): FloatArray
    suspend fun unload()

    /** Statistik generate yang terakhir selesai (null bila belum ada). Baca di dalam EngineHub.gate agar tidak tertukar. */
    val lastStats: GenStats? get() = null
}
