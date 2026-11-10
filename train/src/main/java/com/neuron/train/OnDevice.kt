package com.neuron.train

import com.neuron.model.AiProject
import com.neuron.model.TrainMethod
import com.neuron.model.TrainTarget
import com.neuron.model.TrainingConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import org.json.JSONObject
import java.io.File

/** Temuan preflight. error = training tidak boleh dimulai; warning = boleh, tapi berisiko. */
data class OnDeviceIssue(val error: Boolean, val message: String)

/** "native:NAMA" = folder native lib app; selain itu path absolut. */
fun resolveBinary(raw: String, nativeLibDir: String): File =
    if (raw.startsWith("native:")) File(nativeLibDir, raw.removePrefix("native:")) else File(raw)

/** Jumlah langkah = epoch × ceil(contoh / batch). */
fun stepsFor(examples: Int, cfg: TrainingConfig): Int =
    ((examples + cfg.batchSize - 1) / cfg.batchSize) * cfg.epochs

/** Dataset JSONL -> korpus teks untuk finetune. */
object OnDeviceFormat {
    /** Tulis korpus, kembalikan jumlah contoh yang ditulis. */
    fun write(jsonl: File, dest: File): Int {
        var n = 0
        dest.bufferedWriter().use { w ->
            jsonl.bufferedReader().useLines { lines ->
                lines.forEach { line ->
                    if (line.isBlank()) return@forEach
                    val o = runCatching { JSONObject(line) }.getOrNull() ?: return@forEach
                    val ex = exampleOf(o) ?: return@forEach
                    w.write(ex)
                    n++
                }
            }
        }
        return n
    }

    fun countRecords(jsonl: File): Int = jsonl.useLines { seq -> seq.count { it.isNotBlank() } }

    /**
     * Format sederhana ### Instruction / ### Response. Ini TIDAK mengikuti template chat model,
     * jadi adapter bekerja paling baik bila chat dipakai dengan format yang sama.
     */
    private fun exampleOf(o: JSONObject): String? {
        val msgs = o.optJSONArray("messages")
        if (msgs != null) {
            val sb = StringBuilder()
            for (i in 0 until msgs.length()) {
                val m = msgs.optJSONObject(i) ?: continue
                val content = m.optString("content")
                when (m.optString("role")) {
                    "system" -> sb.append("### System:\n").append(content).append("\n\n")
                    "user" -> sb.append("### Instruction:\n").append(content).append("\n\n")
                    "assistant" -> sb.append("### Response:\n").append(content).append("\n\n")
                }
            }
            return sb.toString().takeIf { it.contains("### Response:") }
        }
        val ins = o.optString("instruction", o.optString("prompt")).trim()
        val inp = o.optString("input", "").trim()
        val out = o.optString("output", o.optString("response")).trim()
        if (ins.isEmpty() || out.isEmpty()) return null
        val user = if (inp.isEmpty()) ins else "$ins\n\n$inp"
        return "### Instruction:\n$user\n\n### Response:\n$out\n\n"
    }
}

/** Pemeriksaan sebelum training di perangkat. Dipanggil di IO karena membaca dataset. */
object OnDevicePreflight {
    fun inspect(cfg: TrainingConfig, project: AiProject, nativeLibDir: String, freeRam: Long, freeDisk: Long): List<OnDeviceIssue> {
        val out = mutableListOf<OnDeviceIssue>()
        fun err(m: String) { out.add(OnDeviceIssue(true, m)) }
        fun warn(m: String) { out.add(OnDeviceIssue(false, m)) }

        if (cfg.target != TrainTarget.ON_DEVICE) err("target bukan ON_DEVICE")
        if (cfg.method != TrainMethod.LORA) err("ON_DEVICE hanya mendukung LORA (metode sekarang: ${cfg.method})")

        val bin = resolveBinary(cfg.onDeviceBinary, nativeLibDir)
        if (!bin.exists() || !bin.canExecute()) {
            err("binary finetune tidak ditemukan atau tidak bisa dijalankan: ${bin.path}. Lihat docs/ON_DEVICE.md")
        }

        val base = File(project.files.modelPath)
        if (!base.exists()) {
            err("model dasar tidak ditemukan: ${project.files.modelPath}")
        } else {
            val q = project.files.quantization.uppercase()
            if (q != "F16" && q != "F32") {
                err("model dasar harus F16 atau F32 untuk LoRA di perangkat (sekarang: ${project.files.quantization.ifBlank { "tidak diisi" }}). Unduh atau konversi ulang ke F16.")
            }
            // Estimasi kasar: bobot + gradien + aktivasi ≈ 3× ukuran berkas.
            val need = base.length() * 3
            if (freeRam in 1L until need) {
                warn("RAM bebas ${fmtGb(freeRam)}, perkiraan kebutuhan ${fmtGb(need)}. Risiko kehabisan memori.")
            }
            if (freeDisk < base.length() / 2) warn("ruang penyimpanan kosong sedikit")
        }

        val ds = File(cfg.datasetPath)
        if (!ds.exists()) {
            err("dataset train belum ada. Buat split di 📚 Data")
        } else {
            val steps = stepsFor(OnDeviceFormat.countRecords(ds), cfg)
            if (steps > cfg.onDeviceMaxSteps) {
                err("jumlah langkah $steps melebihi batas on-device ${cfg.onDeviceMaxSteps}. Kurangi epoch atau naikkan batch.")
            }
        }
        if (cfg.valDatasetPath.isNotBlank()) warn("validasi (val) tidak dipakai di perangkat")
        return out
    }

    private fun fmtGb(b: Long) = "%.1f GB".format(b / (1024.0 * 1024 * 1024))
}

/**
 * Trainer ON_DEVICE: menjalankan binary finetune llama.cpp sebagai proses terpisah.
 * Korpus ditulis ke folder kerja, argumen dibentuk dari [TrainingConfig.onDeviceArgs] dengan placeholder,
 * lalu stdout dibaca baris per baris. Baris yang cocok dengan [TrainingConfig.onDeviceLossRegex] dihitung sebagai step.
 * Hasil: lora.gguf di folder kerja. Lewat "Pakai sebagai LoRA", engine memuatnya (loraPath ikut masuk kunci engine).
 */
class OnDeviceTrainer(private val workRoot: File, private val nativeLibDir: String) : Trainer {
    @Volatile private var proc: Process? = null

    override fun train(cfg: TrainingConfig, project: AiProject): Flow<TrainProgress> = flow {
        val dir = File(workRoot, "od-${System.currentTimeMillis()}").apply { mkdirs() }
        val corpus = File(dir, "train.txt")
        val examples = OnDeviceFormat.write(File(cfg.datasetPath), corpus)
        require(examples > 0) { "Tidak ada contoh yang bisa dipakai dari dataset" }
        val out = File(dir, "lora.gguf")
        val totalSteps = stepsFor(examples, cfg)
        val bin = resolveBinary(cfg.onDeviceBinary, nativeLibDir).path
        val args = buildArgs(cfg, project, corpus, out, totalSteps)
        emit(TrainProgress(0, totalSteps, Float.NaN, "menjalankan: $bin ${args.joinToString(" ")}"))

        val p = ProcessBuilder(listOf(bin) + args).directory(dir).redirectErrorStream(true).start()
        proc = p
        val h = currentCoroutineContext()[Job]?.invokeOnCompletion { p.destroy() }
        try {
            val re = Regex(cfg.onDeviceLossRegex)
            var step = 0
            p.inputStream.bufferedReader().use { r ->
                while (true) {
                    val line = r.readLine() ?: break
                    val loss = re.find(line)?.groupValues?.getOrNull(1)?.toFloatOrNull()
                    if (loss != null) step++
                    emit(TrainProgress(step, totalSteps, loss ?: Float.NaN, line))
                }
            }
            val code = p.waitFor()
            if (code == 0 && out.exists()) {
                emit(TrainProgress(step, totalSteps, Float.NaN, out.absolutePath, status = "saved"))
            } else {
                emit(TrainProgress(step, totalSteps, Float.NaN,
                    "finetune keluar dengan kode $code, adapter ${if (out.exists()) "ada" else "tidak ada"}", status = "error"))
            }
        } finally {
            h?.dispose()
            if (p.isAlive) p.destroy()
            proc = null
        }
    }.flowOn(Dispatchers.IO)

    override suspend fun cancel() { proc?.destroy() }

    /** Ganti placeholder {base} {train} {out} {epochs} {iters} {rank} {alpha} {lr} {batch} {threads} {ctx}. Argumen dipisah spasi. */
    private fun buildArgs(cfg: TrainingConfig, project: AiProject, corpus: File, out: File, steps: Int): List<String> {
        val vars = mapOf(
            "base" to project.files.modelPath,
            "train" to corpus.path,
            "out" to out.path,
            "epochs" to cfg.epochs.toString(),
            "iters" to steps.toString(),
            "rank" to cfg.loraRank.toString(),
            "alpha" to cfg.loraAlpha.toString(),
            "lr" to cfg.learningRate.toString(),
            "batch" to cfg.batchSize.toString(),
            "threads" to project.hardware.threads.toString(),
            "ctx" to project.chat.contextLength.toString(),
        )
        return cfg.onDeviceArgs.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.map { tok ->
            vars.entries.fold(tok) { acc, (k, v) -> acc.replace("{$k}", v) }
        }
    }
}
