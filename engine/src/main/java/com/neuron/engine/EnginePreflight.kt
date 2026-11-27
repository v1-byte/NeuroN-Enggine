package com.neuron.engine

import android.content.Context
import com.neuron.model.AiProject
import java.io.File

/**
 * Pemeriksaan sebelum model dimuat. Setiap kegagalan menjadi [EngineException] dengan jenis yang jelas:
 * NATIVE (libneuron_llama.so / ABI), MODEL (berkas), RAM (perkiraan memori). Dipasang ke [EngineHub.preflight]
 * sehingga berlaku untuk semua jalur (chat, runModel, RAG, Copilot).
 */
object EnginePreflight {
    private const val MIN_MODEL_BYTES = 1_000_000L

    fun check(ctx: Context, p: AiProject) {
        val native = NativeCheck.inspect(ctx)
        if (!native.ok) throw EngineException(EngineErrorKind.NATIVE, native.message())
        val size = checkModelFile(p.files.modelPath)
        checkRam(size, ModelDefaults.effective(p).contextLength, p.hardware.kvCacheType, memAvailableBytes())
    }

    /** Berkas ada, berekstensi .gguf, cukup besar, dan berheader magic "GGUF". Mengembalikan ukuran berkas. */
    internal fun checkModelFile(path: String): Long {
        if (path.isBlank()) throw EngineException(EngineErrorKind.MODEL, "Belum ada model lokal aktif. Unduh atau impor model GGUF dulu.")
        val f = File(path)
        if (!f.isFile) throw EngineException(EngineErrorKind.MODEL, "File model tidak ditemukan: '$path'. Pilih atau unduh model lagi di Model Hub.")
        if (!f.extension.equals("gguf", true)) throw EngineException(EngineErrorKind.MODEL, "Model harus berformat .gguf (ditemukan .${f.extension}).")
        if (f.length() < MIN_MODEL_BYTES) {
            throw EngineException(EngineErrorKind.MODEL, "File model terlalu kecil (${f.length()} byte), kemungkinan unduhan terputus. Unduh ulang.")
        }
        val magic = runCatching { f.inputStream().use { s -> ByteArray(4).also { s.read(it) } } }.getOrNull()
        if (magic == null || !isGgufMagic(magic)) {
            throw EngineException(EngineErrorKind.MODEL, "File ini bukan GGUF yang valid (header salah): ${f.name}. Unduh ulang atau pilih model lain.")
        }
        if (LoraAdapter.isAdapter(f)) {
            throw EngineException(EngineErrorKind.MODEL,
                "${f.name} adalah adapter LoRA, bukan model dasar. Pilih model dasar di Model lokal, lalu pasang adapter ini lewat Lainnya → LoRA.")
        }
        return f.length()
    }

    internal fun isGgufMagic(b: ByteArray): Boolean =
        b.size >= 4 && b[0] == 'G'.code.toByte() && b[1] == 'G'.code.toByte() && b[2] == 'U'.code.toByte() && b[3] == 'F'.code.toByte()

    /** Perkiraan kasar byte KV cache per token (rata-rata model kecil 1-3B); sengaja tidak mencoba presisi. */
    internal fun kvBytesPerToken(kvType: String): Long = when (kvType) {
        "q8_0" -> 85_000L
        "q4_0" -> 45_000L
        else -> 160_000L
    }

    /** Gagal bila perkiraan (model + KV cache) melebihi RAM yang tersedia. [available] null = tidak diketahui, lewati. */
    internal fun checkRam(modelBytes: Long, contextLength: Int, kvType: String, available: Long?) {
        if (available == null) return
        val kv = contextLength.toLong() * kvBytesPerToken(kvType)
        val need = modelBytes + kv
        if (need <= available) return
        val maxCtx = ((available - modelBytes) / kvBytesPerToken(kvType)).toInt() / 256 * 256
        val hint = if (maxCtx >= 512) "Turunkan contextLength ke sekitar $maxCtx atau pakai kvCacheType q8_0/q4_0, lalu coba lagi."
        else "Pakai model yang lebih kecil/kuantisasi lebih rendah, atau tutup aplikasi lain untuk membebaskan RAM."
        throw EngineException(
            EngineErrorKind.RAM,
            "RAM bebas ${mb(available)} MB, perkiraan kebutuhan ${mb(need)} MB (model ${mb(modelBytes)} MB + KV cache ${mb(kv)} MB, perkiraan kasar). $hint",
        )
    }

    private fun mb(b: Long) = b / 1_000_000L

    /** MemAvailable dari /proc/meminfo dalam byte; null bila tidak terbaca. */
    internal fun memAvailableBytes(): Long? = runCatching {
        File("/proc/meminfo").useLines { lines ->
            lines.firstOrNull { it.startsWith("MemAvailable:") }
                ?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull()?.times(1024L)
        }
    }.getOrNull()
}
