package com.neuron.engine

/**
 * Jenis kegagalan engine yang dibedakan untuk pengguna. Kode dikirim ke Flutter sebagai kode PlatformException
 * (EventChannel `neuron/chat` dan MethodChannel `neuron/project`), jadi Dart tidak perlu menebak dari teks.
 */
enum class EngineErrorKind(val code: String) {
    NATIVE("ENGINE_NATIVE"),         // libneuron_llama.so tidak ada / ABI tidak cocok / JNI tidak terhubung
    MODEL("ENGINE_MODEL"),           // berkas model hilang, bukan GGUF, rusak, atau ditolak llama.cpp
    RAM("ENGINE_RAM"),               // memori tidak cukup untuk model + KV cache
    CONTEXT("ENGINE_CONTEXT"),       // contextLength terlalu kecil / prompt terlalu panjang / decode gagal
    CANCELLED("ENGINE_CANCELLED"),   // generate dibatalkan bukan oleh tombol Stop (model dilepas / diganti)
    UNKNOWN("CHAT_ERROR"),           // tidak terklasifikasi: kode lama dipertahankan
}

class EngineException(val kind: EngineErrorKind, message: String, cause: Throwable? = null) : RuntimeException(message, cause)

object EngineErrors {
    /** Awalan yang dipasang kode native (neuron_llama.cpp) pada pesan RuntimeException agar bisa diklasifikasi. */
    private val TAGS = listOf(
        "[NATIVE]" to EngineErrorKind.NATIVE,
        "[MODEL]" to EngineErrorKind.MODEL,
        "[RAM]" to EngineErrorKind.RAM,
        "[CONTEXT]" to EngineErrorKind.CONTEXT,
    )

    fun classify(t: Throwable): EngineException {
        if (t is EngineException) return t
        val raw = t.message.orEmpty()
        for ((tag, kind) in TAGS) {
            if (raw.startsWith(tag)) return EngineException(kind, raw.removePrefix(tag).trim(), t)
        }
        return when (t) {
            is UnsatisfiedLinkError ->
                EngineException(EngineErrorKind.NATIVE, "Library native tidak bisa dimuat atau terhubung: ${raw.ifBlank { t.javaClass.simpleName }}", t)
            is OutOfMemoryError ->
                EngineException(EngineErrorKind.RAM, "Memori habis saat memproses model. Pilih model lebih kecil atau kecilkan contextLength.", t)
            else -> EngineException(EngineErrorKind.UNKNOWN, raw.ifBlank { t.javaClass.simpleName }, t)
        }
    }
}
