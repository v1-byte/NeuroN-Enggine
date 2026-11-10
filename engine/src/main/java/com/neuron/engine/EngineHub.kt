package com.neuron.engine

import com.neuron.model.AiProject
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

    /** Engine mentah yang sudah dimuat untuk konfigurasi [p]; dimuat ulang hanya bila bagian yang memengaruhi model berubah. */
    suspend fun ensure(p: AiProject): InferenceEngine = lock.withLock {
        val k = EngineFactory.key(p)
        if (engine == null || key != k) {
            engine?.unload()
            engine = null
            key = null
            engine = EngineFactory.create(p).also { it.load(p) }
            key = k
        }
        engine!!
    }

    suspend fun unload() = lock.withLock {
        engine?.unload()
        engine = null
        key = null
    }
}
