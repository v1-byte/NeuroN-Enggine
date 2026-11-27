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
class LlamaCppEngine : InferenceEngine, LoraCapable {
    @Volatile private var handle = 0L
    private val genLock = ReentrantLock()
    private val stateLock = Any()          // melindungi handle <-> cancel agar tidak menyentuh memori yang sudah di-free
    private var chatTemplate = ""
    private var biasIds = IntArray(0)
    private var biasVals = FloatArray(0)
    @Volatile private var nCtx = 0             // contextLength yang benar-benar dimuat (dasar pembatasan riwayat)
    @Volatile private var unloadCancel = false // true bila generate dihentikan karena model dilepas, bukan oleh Stop

    // Adapter LoRA yang benar-benar aktif di native (bukan sekadar yang tertulis di proyek).
    @Volatile override var activeLoraPath: String = ""
        private set
    @Volatile override var activeLoraScale: Float = 1f
        private set
    // Adapter yang pernah dimuat pada model ini. llama.cpp baru membebaskannya bersama model, jadi jumlahnya dibatasi.
    private val loadedLoras: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()

    /** Peringatan non-fatal saat load (mis. template chat tidak dikenali llama.cpp). */
    @Volatile var loadWarnings: List<String> = emptyList()
        private set

    @Volatile override var lastStats: GenStats? = null
        private set

    companion object {
        /** Alasan System.loadLibrary gagal (null bila berhasil). Dipakai NativeCheck dan pesan error. */
        @Volatile var loadError: String? = null
            private set
        /** Batas adapter berbeda per sesi model; tiap adapter tetap di RAM sampai model dilepas. */
        const val MAX_LORAS_PER_SESSION = 4
        val available: Boolean = try {
            System.loadLibrary("neuron_llama"); true
        } catch (t: Throwable) {
            loadError = "${t.javaClass.simpleName}: ${t.message}"; false
        }
    }

    private external fun nativeLoad(path: String, ctx: Int, threads: Int, gpuLayers: Int, batch: Int, flashAttn: Boolean, kvType: String, ropeType: Int, ropeScale: Float): Long
    /** Ganti SELURUH adapter aktif dengan [path] (di-cache per path di native). Gagal = adapter aktif menjadi kosong. */
    private external fun nativeLoadLora(h: Long, path: String, scale: Float)
    private external fun nativeClearLora(h: Long)
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
        if (!available) throw EngineException(EngineErrorKind.NATIVE,
            "Library native (libneuron_llama.so) tidak bisa dimuat: ${loadError ?: "penyebab tidak diketahui"}. Pakai APK arm64-v8a yang dibuild dengan -PwithNative.")
        val f = project.files; val hw = project.hardware
        if (f.format != ModelFormat.GGUF) throw EngineException(EngineErrorKind.MODEL, "Engine lokal hanya GGUF. Konversi dulu lewat model/ops.json")
        if (f.modelPath.isBlank() || !File(f.modelPath).isFile) throw EngineException(EngineErrorKind.MODEL,
            "File model tidak ditemukan: '${f.modelPath}' (atur di model/quantization.json)")
        val ctxLen = ModelDefaults.effective(project).contextLength
        if (ctxLen < 256) throw EngineException(EngineErrorKind.CONTEXT, "contextLength $ctxLen terlalu kecil (minimal 256).")
        unload()
        unloadCancel = false
        loadedLoras.clear()
        // Uji sambungan JNI: simbol Java_com_neuron_engine_* baru dicari saat dipanggil pertama kali.
        try { nativeSystemInfo() } catch (e: UnsatisfiedLinkError) {
            throw EngineException(EngineErrorKind.NATIVE,
                "Library native termuat tetapi fungsi JNI tidak cocok dengan aplikasi (${e.message}). Bangun ulang native dari kode yang sama.", e)
        }
        val ropeType = when (hw.ropeScalingType) { "linear" -> 1; "yarn" -> 2; else -> 0 }
        val h = try {
            nativeLoad(f.modelPath, ctxLen, hw.threads.coerceAtLeast(1), hw.numGpuLayers, hw.batchSizeInference.coerceAtLeast(1),
                hw.flashAttention, hw.kvCacheType, ropeType, hw.ropeFreqScale)
        } catch (t: Throwable) { throw EngineErrors.classify(t) }
        // Hasil nativeLoad harus divalidasi eksplisit: 0 berarti tidak ada model, dan memakainya akan menjatuhkan proses.
        if (h == 0L) throw EngineException(EngineErrorKind.MODEL,
            "nativeLoad() mengembalikan handle kosong tanpa pesan error. Lihat logcat tag NeuroN-llama untuk penyebabnya.")
        val warnings = mutableListOf<String>()
        var appliedLora = ""
        try {
            if (f.loraPath.isNotBlank()) {
                // Adapter yang sudah tidak cocok (mis. model dasar diganti) tidak boleh mematikan seluruh chat:
                // model tetap dimuat tanpa adapter dan pengguna diberi tahu.
                try {
                    LoraAdapter.requireScale(f.loraScale)
                    nativeLoadLora(h, f.loraPath, f.loraScale)
                    appliedLora = f.loraPath
                    loadedLoras.add(f.loraPath)
                } catch (t: Throwable) {
                    val w = "Adapter LoRA dilewati karena gagal dimuat (${File(f.loraPath).name}): ${nativeMsg(t)}. Model berjalan tanpa adapter; periksa di Lainnya → LoRA."
                    warnings += w
                    EngineWarnings.post(w)
                }
            }
            // Coba template sekarang supaya fallback ChatML diketahui dari awal, bukan baru terlihat dari jawaban aneh.
            val probe = runCatching {
                nativeApplyTemplate(h, arrayOf("user".toByteArray()), arrayOf("ping".toByteArray()), f.chatTemplate.toByteArray(), true)
            }.getOrNull()
            if (probe == null) warnings += templateWarning(f.chatTemplate)
        } catch (t: Throwable) {
            runCatching { nativeFree(h) }   // jangan bocorkan model yang sudah termuat
            throw t
        }
        handle = h
        activeLoraPath = appliedLora
        activeLoraScale = if (appliedLora.isNotEmpty()) f.loraScale else 1f
        nCtx = ctxLen
        chatTemplate = f.chatTemplate
        biasIds = hw.logitBias.keys.toIntArray()
        biasVals = hw.logitBias.values.toFloatArray()
        loadWarnings = warnings
    }

    override suspend fun setLora(path: String, scale: Float): Unit = withContext(Dispatchers.IO) {
        LoraAdapter.requireScale(scale)
        genLock.lock()   // tunggu generate yang sedang berjalan; adapter tidak boleh berganti di tengah jawaban
        try {
            val h = handle
            if (h == 0L) throw EngineException(EngineErrorKind.MODEL, "Model belum dimuat. Jalankan model dulu di Model Hub.")
            if (path.isBlank()) {
                try { nativeClearLora(h) } catch (t: Throwable) { throw EngineErrors.classify(t) }
                activeLoraPath = ""; activeLoraScale = 1f
                return@withContext
            }
            if (path !in loadedLoras && loadedLoras.size >= MAX_LORAS_PER_SESSION) throw EngineException(EngineErrorKind.RAM,
                "Sudah $MAX_LORAS_PER_SESSION adapter berbeda dimuat pada sesi model ini dan semuanya masih memakai RAM. Lepas model dari memori lalu coba lagi.")
            try {
                nativeLoadLora(h, path, scale)
            } catch (t: Throwable) {
                // Native menjamin adapter aktif kosong bila gagal; EngineHub memasang ulang yang sesuai proyek di permintaan berikutnya.
                activeLoraPath = ""; activeLoraScale = 1f
                throw EngineException(EngineErrorKind.MODEL, "Adapter LoRA gagal dipasang (${File(path).name}): ${nativeMsg(t)}", t)
            }
            loadedLoras.add(path)
            activeLoraPath = path; activeLoraScale = scale
        } finally { genLock.unlock() }
    }

    /** Pesan dari native diawali tag [MODEL]/[RAM] untuk klasifikasi; buang tag itu untuk tampilan. */
    private fun nativeMsg(t: Throwable): String = (t.message ?: t.javaClass.simpleName).replace(Regex("^\\[[A-Z]+\\]\\s*"), "")

    private fun templateWarning(custom: String): String =
        if (custom.isBlank()) "Template chat model ini tidak dikenali llama.cpp. Prompt memakai format ChatML sebagai cadangan; jawaban bisa kacau bila model bukan ChatML."
        else "Template chat di pengaturan model tidak dikenali llama.cpp. Prompt memakai format ChatML sebagai cadangan; periksa nama template."

    private fun buildPrompt(messages: List<ChatMessage>, system: String): ByteArray {
        val all = buildList { if (system.isNotBlank()) add(ChatMessage("system", system)); addAll(messages) }
        val native = nativeApplyTemplate(handle, Array(all.size) { all[it].role.toByteArray() },
            Array(all.size) { all[it].content.toByteArray() }, chatTemplate.toByteArray(), true)
        if (native != null) return native
        // Cadangan ChatML boleh dipakai, tetapi pengguna harus diberi tahu (dikirim ke UI lewat EngineWarnings).
        val warning = templateWarning(chatTemplate)
        Log.w("NeuroN", warning)
        EngineWarnings.post(warning)
        return ChatTemplate.render(messages, system).toByteArray()
    }

    override fun chat(messages: List<ChatMessage>, params: ChatParams): Flow<String> = callbackFlow {
        val h = handle
        if (h == 0L) throw EngineException(EngineErrorKind.MODEL, "Model belum dimuat. Jalankan model dulu di Model Hub.")
        var done = false                    // dijaga stateLock
        val worker = Thread {
            genLock.lock()
            try {
                // unload() bisa lolos di antara pembacaan handle dan lock ini: jangan sentuh memori yang sudah di-free.
                if (handle != h) throw EngineException(EngineErrorKind.CANCELLED, "Model dilepas atau diganti sebelum generate dimulai. Kirim ulang pesan.")
                val limited = HistoryLimiter.limit(messages, nCtx, params.maxTokens, params.systemPrompt)
                if (limited.dropped > 0) EngineWarnings.post("Riwayat chat dipangkas: ${limited.dropped} pesan terlama tidak dikirim ke model agar muat di konteks $nCtx token.")
                val prompt = buildPrompt(limited.messages, params.systemPrompt)
                val dec = Utf8Stream(); val stop = StopMatcher(params.stopSequences)
                val t0 = System.nanoTime(); var nTok = 0
                nativeGenerate(h, prompt, params.temperature, params.topP, params.topK, params.minP,
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
                // Dihentikan karena model dilepas (bukan Stop dari pengguna): jangan tampil seolah jawaban selesai.
                if (unloadCancel) close(EngineException(EngineErrorKind.CANCELLED, "Generate dibatalkan karena model dilepas atau diganti. Jawaban terpotong; kirim ulang pesan."))
                else close()
            } catch (e: Throwable) { close(EngineErrors.classify(e)) } finally {
                synchronized(stateLock) { done = true }   // setelah ini cancel lama tidak boleh mengenai permintaan berikutnya
                genLock.unlock()
            }
        }
        worker.start()
        awaitClose { synchronized(stateLock) { if (!done && handle == h) nativeCancel(h) } }
    }.buffer(Channel.UNLIMITED)

    override suspend fun embed(text: String): FloatArray = withContext(Dispatchers.IO) {
        genLock.lock()
        try {
            val h = handle
            if (h == 0L) throw EngineException(EngineErrorKind.MODEL, "Model belum dimuat. Jalankan model dulu di Model Hub.")
            try { nativeEmbed(h, text.toByteArray()) } catch (t: Throwable) { throw EngineErrors.classify(t) }
        } finally { genLock.unlock() }
    }

    override suspend fun unload(): Unit = withContext(Dispatchers.IO) {
        val h = handle
        if (h == 0L) return@withContext
        synchronized(stateLock) { if (handle == h) { unloadCancel = true; nativeCancel(h) } }
        genLock.lock()                       // tunggu generate yang berjalan selesai
        try {
            synchronized(stateLock) { handle = 0L }
            nativeFree(h)
            activeLoraPath = ""; activeLoraScale = 1f; loadedLoras.clear()
        } finally { genLock.unlock() }
    }
}
