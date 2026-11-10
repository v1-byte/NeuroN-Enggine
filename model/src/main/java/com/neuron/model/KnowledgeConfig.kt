package com.neuron.model
import kotlinx.serialization.Serializable

/** 4. Pengetahuan tambahan (RAG) */
@Serializable
data class KnowledgeConfig(
    val ragEnabled: Boolean = false,
    val embeddingModelPath: String = "",
    val vectorDb: String = "sqlite",       // sqlite | (nanti) hnsw
    val chunkSize: Int = 512,
    val chunkOverlap: Int = 64,
    val topK: Int = 4,
    val minScore: Float = 0f,              // buang hasil dengan kemiripan cosine di bawah ini (0 = tanpa filter)
    val knowledgeFiles: List<String> = emptyList(),   // file/folder; relatif = di folder knowledge app; "." = semua
)
