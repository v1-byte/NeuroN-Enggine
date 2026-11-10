package com.neuron.rag

import com.neuron.engine.InferenceEngine
import com.neuron.model.KnowledgeConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.security.MessageDigest
import kotlin.math.sqrt

data class SyncReport(val indexed: Int, val skipped: Int, val removed: Int, val failed: List<String>, val chunks: Int)

/** Prompt yang menyisipkan konteks ke pesan terakhir pengguna. Ubah di sini jika model kecil kurang patuh. */
object RagPrompt {
    fun augment(question: String, hits: List<Hit>, nameOf: (String) -> String): String = buildString {
        append("Use the CONTEXT below to answer. If the answer is not in the context, say you could not find it in the documents. ")
        append("Cite sources like [1], [2]. Answer in the same language as the question.\n\nCONTEXT:\n")
        hits.forEachIndexed { i, h -> append("[${i + 1}] (${nameOf(h.source)})\n${h.text}\n\n") }
        append("QUESTION: ").append(question)
    }
}

/**
 * Indeks pengetahuan: file -> teks -> chunk -> embedding -> SQLite. `embedderId` mengidentifikasi model embedding;
 * jika berubah (atau chunkSize/overlap berubah) seluruh indeks dibangun ulang karena vektornya tidak sebanding.
 */
class RagPipeline(
    private val embedder: InferenceEngine,
    private val store: VectorStore,
    private val cfg: KnowledgeConfig,
    private val parser: FileParser,
    private val embedderId: String,
) {
    suspend fun sync(onLog: (String) -> Unit = {}): SyncReport {
        val sig = "$embedderId|${cfg.chunkSize}|${cfg.chunkOverlap}"
        if (store.meta("sig") != sig) {
            if (store.count() > 0) onLog("Model embedding / ukuran chunk berubah: indeks dibangun ulang")
            store.clear(); store.setMeta("sig", sig)
        }
        val files = parser.expand(cfg.knowledgeFiles)
        var removed = 0
        for (s in store.sources()) if (s !in files) { store.deleteSource(s); removed++; onLog("Dihapus dari indeks: ${parser.displayName(s)}") }

        var indexed = 0; var skipped = 0; var total = 0
        val failed = ArrayList<String>()
        files.forEachIndexed { i, path ->
            currentCoroutineContext().ensureActive()
            val name = parser.displayName(path)
            try {
                val text = parser.read(path)
                val hash = sha256(text)
                if (store.sourceHash(path) == hash) { skipped++; onLog("[${i + 1}/${files.size}] $name: tidak berubah"); return@forEachIndexed }
                val chunks = Chunker.split(text, cfg.chunkSize, cfg.chunkOverlap)
                if (chunks.isEmpty()) { failed += "$name: kosong"; onLog("[${i + 1}/${files.size}] $name: teks kosong (PDF hasil scan?)"); return@forEachIndexed }
                val items = ArrayList<Pair<String, FloatArray>>(chunks.size)
                for ((j, ch) in chunks.withIndex()) {
                    currentCoroutineContext().ensureActive()
                    items += ch to embedder.embed(ch)
                    if (j % 10 == 9) onLog("[${i + 1}/${files.size}] $name: ${j + 1}/${chunks.size} chunk")
                }
                store.replaceSource(path, hash, items)
                indexed++; total += items.size
                onLog("[${i + 1}/${files.size}] $name: ${items.size} chunk diindeks")
            } catch (e: CancellationException) { throw e
            } catch (e: Throwable) { failed += "$name: ${e.message}"; onLog("[${i + 1}/${files.size}] $name GAGAL: ${e.message}") }
        }
        return SyncReport(indexed, skipped, removed, failed, total)
    }

    suspend fun retrieve(query: String): List<Hit> {
        if (store.count() == 0) return emptyList()
        return store.search(embedder.embed(query), cfg.topK).filter { it.score >= cfg.minScore }
    }

    private fun sha256(s: String) = MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }
}

fun cosine(a: FloatArray, b: FloatArray): Float {
    var d = 0f; var na = 0f; var nb = 0f
    for (i in a.indices) { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    return d / (sqrt(na) * sqrt(nb) + 1e-9f)
}
