package com.neuron.engine

import com.neuron.model.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.withContext
import android.util.Log
import java.io.File
import java.util.concurrent.locks.ReentrantLock

/** Engine lokal via llama.cpp (JNI). Hanya GGUF. Satu generate pada satu waktu (permintaan lain menunggu). */
class LlamaCppEngine : InferenceEngine {
    @Volatile private var handle = 0L
    private val genLock = ReentrantLock()
    private val stateLock = Any()          // melindungi handle <-> cancel agar tidak menyentuh memori yang sudah di-free
    private var chatTemplate = ""
    private var biasIds = IntArray(0)
    private var biasVals = FloatArray(0)

    @Volatile override var lastStats: GenStats? = null
        private set

    companion object {
        val available: Boolean = try { System.loadLibrary("neuron_llama"); true } catch (_: UnsatisfiedLinkError) { false }
    }

    private external fun nativeLoad(path: String, ctx: Int, threads: Int, gpuLayers: Int, batch: Int, flashAttn: Boolean, kvType: String, ropeType: Int, ropeScale: Float): Long
    private external fun nativeLoadLora(h: Long, path: String, scale: Float)
    private external fun nativeApplyTemplate(h: Long, roles: Array<ByteArray>, contents: Array<ByteArray>, tmpl: ByteArray, addAssistant: Boolean): ByteArray?
    private external fun nativeGenerate(h: Long, prompt: ByteArray, temp: Float, topP: Float, topK: Int, minP: Float, repeat: Float, presence: Float, freq: Float, maxTokens: Int, seed: Long, biasIds: IntArray, biasVals: FloatArray, cb: TokenCallback)
    private external fun nativeEmbed(h: Long, text: ByteArray): FloatArray
    private external fun nativeFree(h: Long)
    private external fun nativeSystemInfo(): String

    /** Ringkasan backend/CPU feature + status Vulkan (untuk dicek di UI/log). */
    fun backendInfo(): String = if (available) nativeSystemInfo() else "native tidak tersedia"
    private external fun nativeCancel(h: Long)

    interface TokenCallback { fun onToken(piece: ByteArray): Boolean }   // false = berhenti

    override suspend fun load(project: AiProject): Unit = withContext(Dispatchers.IO) {
        check(available) { "Library native belum ada. Build dengan -PwithNative (lihat docs/NATIVE.md)" }
        val f = project.files; val hw = project.hardware
        require(f.format == ModelFormat.GGUF) { "Engine lokal hanya GGUF. Konversi dulu lewat model/ops.json" }
        require(f.modelPath.isNotBlank() && File(f.modelPath).exists()) { "File model tidak ditemukan: '${f.modelPath}' (atur di model/quantization.json)" }
        unload()
        val ropeType = when (hw.ropeScalingType) { "linear" -> 1; "yarn" -> 2; else -> 0 }
        handle = nativeLoad(f.modelPath, ModelDefaults.effective(project).contextLength, hw.threads, hw.numGpuLayers, hw.batchSizeInference,
            hw.flashAttention, hw.kvCacheType, ropeType, hw.ropeFreqScale)
        if (f.loraPath.isNotBlank()) nativeLoadLora(handle, f.loraPath, f.loraScale)
        chatTemplate = f.chatTemplate
        biasIds = hw.logitBias.keys.toIntArray()
        biasVals = hw.logitBias.values.toFloatArray()
    }

    private fun buildPrompt(messages: List<ChatMessage>, system: String): ByteArray {
        val all = buildList { if (system.isNotBlank()) add(ChatMessage("system", system)); addAll(messages) }
        val native = nativeApplyTemplate(handle, Array(all.size) { all[it].role.toByteArray() },
            Array(all.size) { all[it].content.toByteArray() }, chatTemplate.toByteArray(), true)
        if (native == null) Log.w("NeuroN", "Template model tidak dikenali llama.cpp, memakai ChatML")
        return native ?: ChatTemplate.render(messages, system).toByteArray()   // cadangan: ChatML
    }

    override fun chat(messages: List<ChatMessage>, params: ChatParams): Flow<String> = callbackFlow {
        val h = handle
        check(h != 0L) { "Model belum dimuat" }
        var done = false                    // dijaga stateLock
        val worker = Thread {
            genLock.lock()
            try {
                val dec = Utf8Stream(); val stop = StopMatcher(params.stopSequences)
                val t0 = System.nanoTime(); var nTok = 0
                nativeGenerate(h, buildPrompt(messages, params.systemPrompt), params.temperature, params.topP, params.topK, params.minP,
                    params.repeatPenalty, params.presencePenalty, params.frequencyPenalty, params.maxTokens, params.seed,
                    biasIds, biasVals, object : TokenCallback {
                        override fun onToken(piece: ByteArray): Boolean {
                            nTok++
                            val text = dec.push(piece)
                            if (text.isNotEmpty()) { val out = stop.feed(text); if (out.isNotEmpty()) trySend(out) }
                            return !stop.stopped
                        }
                    })
                val rest = stop.feed(dec.flush()) + stop.flush()
                if (rest.isNotEmpty()) trySend(rest)
                lastStats = GenStats(0, nTok, (System.nanoTime() - t0) / 1_000_000)
                close()
            } catch (e: Throwable) { close(e) } finally {
                synchronized(stateLock) { done = true }   // setelah ini cancel lama tidak boleh mengenai permintaan berikutnya
                genLock.unlock()
            }
        }
        worker.start()
        awaitClose { synchronized(stateLock) { if (!done && handle == h) nativeCancel(h) } }
    }.buffer(Channel.UNLIMITED)

    override suspend fun embed(text: String): FloatArray = withContext(Dispatchers.IO) {
        genLock.lock()
        try { nativeEmbed(handle, text.toByteArray()) } finally { genLock.unlock() }
    }

    override suspend fun unload(): Unit = withContext(Dispatchers.IO) {
        val h = handle
        if (h == 0L) return@withContext
        synchronized(stateLock) { if (handle == h) nativeCancel(h) }
        genLock.lock()                       // tunggu generate yang berjalan selesai
        try { synchronized(stateLock) { handle = 0L }; nativeFree(h) } finally { genLock.unlock() }
    }
}
