package com.neuron.engine

import java.io.File

/**
 * Ringkasan adapter LoRA berformat GGUF (hasil `convert_lora_to_gguf.py` atau konversi di server NeuroN Trainer).
 * Dibaca dari header saja; bobot tidak disentuh. Tanpa dependensi Android supaya bisa dites sebagai JUnit biasa.
 */
data class LoraAdapterInfo(
    val architecture: String,
    val name: String,
    /** `general.base_model.0.name` bila dicatat konverter; hanya petunjuk, bukan jaminan. */
    val baseModel: String?,
    val alpha: Double?,
    val tensorCount: Long,
    val sizeBytes: Long,
)

/** Hasil pemeriksaan kecocokan adapter dengan model dasar. [problems] menolak pemasangan; [warnings] hanya memberi tahu. */
data class LoraVerdict(val problems: List<String>, val warnings: List<String>) {
    val compatible: Boolean get() = problems.isEmpty()
}

/**
 * Engine yang bisa memasang/melepas adapter LoRA pada model yang SUDAH dimuat, tanpa memuat ulang model
 * (memuat ulang model beberapa GB di HP bisa puluhan detik).
 */
interface LoraCapable {
    /** Path adapter yang benar-benar aktif di engine; kosong = tanpa adapter. */
    val activeLoraPath: String
    val activeLoraScale: Float

    /** Ganti adapter aktif dengan [path] berskala [scale]; [path] kosong = lepas adapter. Menunggu generate yang sedang jalan. */
    suspend fun setLora(path: String, scale: Float)
}

object LoraAdapter {
    const val MAX_SCALE = 4f

    fun requireScale(scale: Float) {
        require(scale.isFinite() && scale in 0f..MAX_SCALE) { "Skala LoRA harus antara 0 dan $MAX_SCALE (nilai: $scale)" }
    }

    /** True bila [file] adalah GGUF adapter LoRA. Berkas lain/rusak = false (tidak pernah melempar). */
    fun isAdapter(file: File): Boolean = runCatching { inspect(file) }.isSuccess

    /** Baca dan periksa adapter. Melempar [GgufException] dengan pesan yang bisa langsung ditampilkan ke pengguna. */
    fun inspect(file: File): LoraAdapterInfo {
        if (!file.isFile) throw GgufException("Berkas adapter tidak ditemukan: ${file.name}")
        val magic = ByteArray(4)
        val n = file.inputStream().use { it.read(magic) }
        if (n == 4 && String(magic, Charsets.ISO_8859_1) == "ggla")
            throw GgufException("${file.name} memakai format adapter lama (ggla) yang tidak didukung. Konversi ulang ke GGUF lewat Operasi model.")
        return describe(GgufReader.read(file), file.name, file.length())
    }

    internal fun describe(g: GgufFile, fileName: String, size: Long): LoraAdapterInfo {
        val type = g.string("general.type")
        val adapterType = g.string("adapter.type")
        if (type != "adapter" && adapterType == null)
            throw GgufException("$fileName bukan adapter LoRA, melainkan model biasa. Pakai lewat Model lokal sebagai model dasar.")
        if (adapterType != null && adapterType != "lora")
            throw GgufException("Jenis adapter '$adapterType' tidak didukung; hanya LoRA.")
        val arch = g.string("general.architecture")?.takeIf { it.isNotBlank() }
            ?: throw GgufException("$fileName tidak mencatat general.architecture; adapter tidak bisa dicocokkan dengan model.")
        return LoraAdapterInfo(
            architecture = arch,
            name = g.string("general.name") ?: fileName.removeSuffix(".gguf"),
            baseModel = g.string("general.base_model.0.name")?.takeIf { it.isNotBlank() },
            alpha = (g.entry("adapter.lora.alpha")?.value as? Number)?.toDouble(),
            tensorCount = g.tensorCount,
            sizeBytes = size,
        )
    }

    /**
     * Periksa [info] terhadap header model dasar [base]. Yang bisa dipastikan dari header hanya arsitektur;
     * ukuran/varian yang berbeda baru ketahuan saat llama.cpp memuat, jadi itu hanya jadi peringatan.
     */
    fun check(info: LoraAdapterInfo, base: GgufFile?): LoraVerdict {
        val problems = mutableListOf<String>()
        val warnings = mutableListOf<String>()
        if (base == null) {
            problems += "Model dasar belum dipilih atau headernya tidak terbaca. Pilih model aktif dulu di Model lokal."
            return LoraVerdict(problems, warnings)
        }
        if (base.string("general.type") == "adapter" || base.entry("adapter.type") != null) {
            problems += "Model aktif sendiri adalah adapter LoRA, bukan model dasar. Pilih model dasar di Model lokal."
            return LoraVerdict(problems, warnings)
        }
        val baseArch = base.string("general.architecture")
        if (baseArch == null) warnings += "Model aktif tidak mencatat arsitektur; kecocokan adapter tidak bisa dipastikan."
        else if (baseArch != info.architecture)
            problems += "Adapter ini untuk arsitektur '${info.architecture}', sedangkan model aktif '$baseArch'. Pakai adapter yang dilatih dari model dasar yang sama."
        val hint = info.baseModel
        val baseName = base.string("general.name")
        if (!hint.isNullOrBlank() && !baseName.isNullOrBlank() && !sameModel(hint, baseName))
            warnings += "Adapter dilatih dari '$hint', sedangkan model aktif bernama '$baseName'. Arsitektur sama, tetapi bila ukuran atau varian berbeda adapter akan ditolak saat dimuat atau membuat jawaban kacau."
        return LoraVerdict(problems, warnings)
    }

    internal fun sameModel(a: String, b: String): Boolean {
        val x = norm(a); val y = norm(b)
        return x.isNotEmpty() && y.isNotEmpty() && (x.contains(y) || y.contains(x))
    }

    private fun norm(s: String) = s.lowercase().filter { it.isLetterOrDigit() }
}
