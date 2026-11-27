package com.neuron.engine

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.withLock
import java.io.File

/**
 * Kelola adapter LoRA di perangkat: simpan di `models/loras/`, periksa kecocokan dengan model aktif,
 * pasang/lepas (langsung pada model yang sudah dimuat, tanpa memuat ulang), dan uji A/B.
 *
 * Adapter disimpan terpisah dari model dasar supaya tidak muncul di daftar model dan tidak bisa
 * diaktifkan sebagai model dasar. Berkas adapter tidak pernah ditimpa: nama bentrok diberi akhiran -2, -3, ...
 * (cache adapter di native berdasarkan path, jadi path yang sama tidak boleh berisi berkas lain).
 */
internal object LoraBridge {
    fun modelsRoot(ctx: Context): File =
        (ctx.getExternalFilesDir("models") ?: File(ctx.filesDir, "models")).apply { mkdirs() }

    fun dir(ctx: Context): File = File(modelsRoot(ctx), "loras").apply { mkdirs() }

    /** Adapter harus berada di folder LoRA NeuroN dan berekstensi .gguf. */
    fun adapterFile(ctx: Context, path: String): File {
        val f = File(path).canonicalFile
        val root = dir(ctx).canonicalFile
        require(f.isFile && f.extension.equals("gguf", true) && f.path.startsWith(root.path + File.separator)) {
            "Adapter harus berada di folder LoRA NeuroN (.gguf). Impor dulu lewat tombol Impor."
        }
        return f
    }

    private fun round2(x: Float): Double = Math.round(x * 100f) / 100.0

    private fun baseHeader(path: String): GgufFile? =
        runCatching { File(path).takeIf { it.isFile }?.let { GgufReader.read(it) } }.getOrNull()

    private fun uniqueTarget(folder: File, rawName: String): File {
        val clean = rawName.replace(Regex("[^A-Za-z0-9._-]"), "_").removeSuffix(".gguf").ifBlank { "adapter" }
        var n = 1
        var target = File(folder, "$clean.gguf")
        while (target.exists()) { n++; target = File(folder, "$clean-$n.gguf") }
        return target
    }

    /**
     * Adapter hasil unduhan trainer versi lama tersimpan di folder model dan muncul di daftar model dasar.
     * Pindahkan ke folder LoRA dan benahi referensi proyek. Mengembalikan catatan untuk ditampilkan.
     */
    fun migrateStray(ctx: Context): List<String> {
        val stray = modelsRoot(ctx).listFiles { f ->
            f.isFile && f.extension.equals("gguf", true) && f.name.contains("lora", true) && LoraAdapter.isAdapter(f)
        } ?: return emptyList()
        if (stray.isEmpty()) return emptyList()
        val notes = mutableListOf<String>()
        var project = ProjectStore.load(ctx)
        var changed = false
        for (f in stray) {
            val target = uniqueTarget(dir(ctx), f.name)
            if (!f.renameTo(target)) continue
            notes += "${f.name} dipindah ke folder LoRA (sebelumnya tercampur di daftar model dasar)."
            if (project.files.loraPath == f.absolutePath) {
                project = project.copy(files = project.files.copy(loraPath = target.absolutePath)); changed = true
            }
            if (project.files.modelPath == f.absolutePath) {
                project = project.copy(files = project.files.copy(modelPath = "")); changed = true
                notes += "${f.name} sempat dipilih sebagai model dasar; pilihan itu dikosongkan. Pilih model dasar yang benar di Model lokal."
            }
        }
        if (changed) ProjectStore.save(ctx, project)
        return notes
    }

    private fun describe(file: File, base: GgufFile?, activePath: String): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>(
            "name" to file.name, "path" to file.absolutePath, "size" to file.length(),
            "modified" to file.lastModified(), "active" to (file.absolutePath == activePath),
        )
        try {
            val info = LoraAdapter.inspect(file)
            val verdict = LoraAdapter.check(info, base)
            out["valid"] = true
            out["arch"] = info.architecture
            out["alpha"] = info.alpha
            out["baseModel"] = info.baseModel
            out["tensors"] = info.tensorCount
            out["compatible"] = verdict.compatible
            out["problems"] = verdict.problems
            out["warnings"] = verdict.warnings
        } catch (e: Exception) {
            out["valid"] = false
            out["compatible"] = false
            out["problems"] = listOf(e.message ?: "Berkas adapter tidak terbaca")
            out["warnings"] = emptyList<String>()
        }
        return out
    }

    fun state(ctx: Context): Map<String, Any?> {
        val p = ProjectStore.load(ctx)
        val live = EngineHub.loraSnapshot
        val loraPath = p.files.loraPath
        return mapOf(
            "modelPath" to p.files.modelPath,
            "modelName" to (if (p.files.modelPath.isBlank()) "" else File(p.files.modelPath).name),
            "modelArch" to baseHeader(p.files.modelPath)?.string("general.architecture"),
            "loraPath" to loraPath,
            "loraName" to (if (loraPath.isBlank()) "" else File(loraPath).name),
            "scale" to round2(p.files.loraScale),
            "engineLoaded" to EngineHub.isLoaded,
            "engineLoraPath" to (live?.first ?: ""),
            "engineLoraScale" to round2(live?.second ?: 1f),
            "nativeAvailable" to LlamaCppEngine.available,
            "maxScale" to LoraAdapter.MAX_SCALE.toDouble(),
        )
    }

    fun list(ctx: Context): Map<String, Any?> {
        val notes = migrateStray(ctx)
        val p = ProjectStore.load(ctx)
        val base = baseHeader(p.files.modelPath)
        val files = dir(ctx).listFiles { f -> f.isFile && f.extension.equals("gguf", true) }
            ?.sortedByDescending { it.lastModified() } ?: emptyList()
        return mapOf("adapters" to files.map { describe(it, base, p.files.loraPath) }, "notes" to notes)
    }

    fun importAdapter(ctx: Context, source: String): Map<String, Any?> {
        val src = File(source)
        require(src.isFile && src.extension.equals("gguf", true)) { "Pilih berkas adapter .gguf yang valid" }
        LoraAdapter.inspect(src)   // menolak model biasa, format lama, dan berkas rusak dengan pesan yang jelas
        val folder = dir(ctx)
        require(folder.usableSpace > src.length() + 32L * 1024 * 1024) { "Ruang penyimpanan tidak cukup untuk menyalin adapter ini." }
        val target = uniqueTarget(folder, src.name)
        val tmp = File(target.path + ".part")
        try {
            src.inputStream().use { input -> tmp.outputStream().use { output -> input.copyTo(output) } }
            check(tmp.length() == src.length()) { "Salinan adapter tidak lengkap" }
            check(tmp.renameTo(target)) { "Gagal menyimpan adapter" }
        } finally {
            tmp.delete()
        }
        val p = ProjectStore.load(ctx)
        return describe(target, baseHeader(p.files.modelPath), p.files.loraPath)
    }

    /** Pasang adapter. Model yang sudah dimuat langsung berganti; bila belum, adapter dipasang saat model dimuat. */
    fun attach(ctx: Context, path: String, scale: Float): Map<String, Any?> {
        val f = adapterFile(ctx, path)
        LoraAdapter.requireScale(scale)
        val before = ProjectStore.load(ctx)
        require(before.files.modelPath.isNotBlank()) { "Pilih model dasar dulu di Model lokal." }
        val info = LoraAdapter.inspect(f)
        val verdict = LoraAdapter.check(info, baseHeader(before.files.modelPath))
        require(verdict.compatible) { verdict.problems.joinToString(" ") }
        ProjectStore.save(ctx, before.copy(files = before.files.copy(loraPath = f.absolutePath, loraScale = scale)))
        val hot = try {
            runBlocking(Dispatchers.IO) { EngineHub.applyLora(f.absolutePath, scale) }
        } catch (t: Throwable) {
            ProjectStore.save(ctx, before)   // gagal dipasang: proyek kembali ke keadaan semula
            throw t
        }
        return mapOf("ok" to true, "hot" to hot, "warnings" to verdict.warnings, "path" to f.absolutePath)
    }

    fun detach(ctx: Context): Map<String, Any?> {
        val p = ProjectStore.load(ctx)
        ProjectStore.save(ctx, p.copy(files = p.files.copy(loraPath = "")))
        val hot = runBlocking(Dispatchers.IO) { EngineHub.applyLora("", 1f) }
        return mapOf("ok" to true, "hot" to hot)
    }

    fun setScale(ctx: Context, scale: Float): Map<String, Any?> {
        LoraAdapter.requireScale(scale)
        val before = ProjectStore.load(ctx)
        require(before.files.loraPath.isNotBlank()) { "Belum ada adapter terpasang." }
        ProjectStore.save(ctx, before.copy(files = before.files.copy(loraScale = scale)))
        val hot = try {
            runBlocking(Dispatchers.IO) { EngineHub.applyLora(before.files.loraPath, scale) }
        } catch (t: Throwable) {
            ProjectStore.save(ctx, before)
            throw t
        }
        return mapOf("ok" to true, "hot" to hot, "scale" to round2(scale))
    }

    fun delete(ctx: Context, path: String): Map<String, Any?> {
        val f = adapterFile(ctx, path)
        val p = ProjectStore.load(ctx)
        require(p.files.loraPath.isBlank() || File(p.files.loraPath).canonicalPath != f.path) { "Lepas adapter ini dulu sebelum menghapusnya." }
        check(f.delete()) { "Adapter gagal dihapus" }
        return mapOf("ok" to true, "path" to f.absolutePath)
    }

    /**
     * Unduhan adapter dari trainer: periksa, lalu pasang hanya bila cocok dengan model aktif.
     * Berkas selalu disimpan; yang tidak cocok tidak dipasang dan alasannya dikembalikan.
     */
    fun attachDownloaded(ctx: Context, file: File): Map<String, Any?> {
        runCatching { LoraAdapter.inspect(file) }.onFailure {
            file.delete()
            throw IllegalStateException("Berkas yang diunduh bukan adapter LoRA GGUF yang valid: ${it.message}")
        }
        return try {
            attach(ctx, file.absolutePath, 1f) + mapOf("attached" to true)
        } catch (e: Exception) {
            mapOf("attached" to false, "note" to (e.message ?: "Adapter tidak dipasang"), "path" to file.absolutePath)
        }
    }

    /**
     * Uji A/B: prompt yang sama dijalankan tanpa adapter lalu dengan adapter, greedy (temperature 0, seed tetap)
     * supaya perbedaan jawaban berasal dari adapter, bukan dari sampling. Engine mentah dipakai (tanpa tools/guardrail).
     * Setelah selesai, adapter dikembalikan sesuai proyek, juga bila terjadi error.
     */
    fun abTest(ctx: Context, prompt: String, maxTokens: Int): Map<String, Any?> = runBlocking(Dispatchers.IO) {
        require(prompt.isNotBlank()) { "Tulis prompt uji dulu." }
        require(prompt.length <= 4000) { "Prompt uji maksimal 4000 karakter." }
        val p = ProjectStore.load(ctx)
        require(p.files.loraPath.isNotBlank()) { "Pasang adapter dulu sebelum uji A/B." }
        val wantPath = p.files.loraPath
        val wantScale = p.files.loraScale
        val engine = EngineHub.ensure(p)
        val cap = engine as? LoraCapable
            ?: throw EngineException(EngineErrorKind.MODEL, "Engine ini tidak mendukung penggantian adapter.")
        val defaults = ModelDefaults.effective(p)
        val params = defaults.copy(temperature = 0f, seed = 42L, maxTokens = maxTokens.coerceIn(16, 512))
        val messages = listOf(ChatMessage("user", prompt))
        EngineHub.gate.withLock {
            try {
                val plain = generate(engine, cap, "", 1f, messages, params)
                val tuned = generate(engine, cap, wantPath, wantScale, messages, params)
                mapOf(
                    "base" to plain, "adapter" to tuned,
                    "adapterName" to File(wantPath).name, "scale" to round2(wantScale),
                    "same" to (plain["text"] == tuned["text"]),
                )
            } finally {
                runCatching { cap.setLora(wantPath, wantScale) }
            }
        }
    }

    private suspend fun generate(
        engine: InferenceEngine, cap: LoraCapable, path: String, scale: Float,
        messages: List<ChatMessage>, params: com.neuron.model.ChatParams,
    ): Map<String, Any?> {
        if (cap.activeLoraPath != path || (path.isNotBlank() && cap.activeLoraScale != scale)) cap.setLora(path, scale)
        val sb = StringBuilder()
        engine.chat(messages, params).collect { sb.append(it) }
        val st = engine.lastStats
        return mapOf(
            "text" to sb.toString().trim(),
            "tokens" to (st?.completionTokens ?: 0),
            "ms" to (st?.millis ?: 0L),
            "tps" to Math.round((st?.tokensPerSecond ?: 0.0) * 10.0) / 10.0,
        )
    }
}
