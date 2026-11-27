package com.neuron.engine

import com.neuron.model.AiProject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Satu engine bersama untuk chat uji (UI) dan server lokal, supaya model tidak dimuat dua kali.
 * [gate] menjaga satu permintaan generate pada satu waktu: native llama.cpp tidak aman dipanggil paralel.
 */
object EngineHub {
    val gate = Mutex()
    private val lock = Mutex()
    private var engine: InferenceEngine? = null
    private var key: String? = null

    /**
     * Pemeriksaan sebelum model (re)load: validasi native/ABI, berkas model, dan RAM (lihat [EnginePreflight]).
     * Dipasang oleh bridge aplikasi; null di unit test. Dijalankan setelah engine lama dilepas, supaya RAM yang
     * dibaca sudah memperhitungkan model sebelumnya yang dibebaskan.
     */
    @Volatile var preflight: ((AiProject) -> Unit)? = null

    /** True bila ada engine yang sedang dimuat di memori. */
    val isLoaded: Boolean get() = engine != null

    /** Engine mentah yang sudah dimuat untuk konfigurasi [p]; dimuat ulang hanya bila bagian yang memengaruhi model berubah. */
    suspend fun ensure(p: AiProject): InferenceEngine = lock.withLock {
        val k = EngineFactory.key(p)
        if (engine == null || key != k) {
            engine?.unload()
            engine = null
            key = null
            preflight?.invoke(p)
            engine = EngineFactory.create(p).also { it.load(p) }   // load() sudah memasang adapter dari proyek
            key = k
        } else {
            syncLora(engine!!, p)   // model sama: cukup tukar adapter, tanpa memuat ulang model
        }
        engine!!
    }

    /** Samakan adapter aktif engine dengan proyek. Gagal = jalan tanpa adapter dan beri tahu pengguna, bukan mematikan chat. */
    private suspend fun syncLora(e: InferenceEngine, p: AiProject) {
        val cap = e as? LoraCapable ?: return
        val want = p.files.loraPath
        val scale = p.files.loraScale
        if (cap.activeLoraPath == want && (want.isBlank() || cap.activeLoraScale == scale)) return
        try {
            cap.setLora(want, scale)
        } catch (t: Throwable) {
            if (t is CancellationException) throw t
            runCatching { cap.setLora("", 1f) }
            EngineWarnings.post("Adapter LoRA tidak bisa dipasang (${java.io.File(want).name}): ${t.message}. Model berjalan tanpa adapter.")
        }
    }

    /**
     * Pasang/lepas adapter pada engine yang SUDAH dimuat. False bila belum ada engine di memori
     * (adapter dari proyek akan dipasang saat model dimuat). Melempar bila pemasangan gagal.
     */
    suspend fun applyLora(path: String, scale: Float): Boolean = lock.withLock {
        val cap = engine as? LoraCapable ?: return@withLock false
        cap.setLora(path, scale)
        true
    }

    /** Adapter yang benar-benar aktif di engine yang termuat (path, skala); null bila tidak ada engine yang mendukung. */
    val loraSnapshot: Pair<String, Float>? get() = (engine as? LoraCapable)?.let { it.activeLoraPath to it.activeLoraScale }

    suspend fun unload() = lock.withLock {
        engine?.unload()
        engine = null
        key = null
    }
}
