package com.neuron.engine

import android.content.Context
import com.neuron.model.ModelOp
import com.neuron.model.ModelOpsConfig
import com.neuron.model.TrainTarget
import com.neuron.model.TrainingConfig
import com.neuron.model.validate
import com.neuron.project.VirtualTree
import com.neuron.train.DatasetImporter
import com.neuron.train.ModelOpsClient
import com.neuron.train.OpEvent
import com.neuron.train.RemoteTrainer
import com.neuron.train.TrainProgress
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Bridge khusus alur training Flutter. API key trainer disimpan terenkripsi di SecretStore. */
internal object TrainingBridge {
    private const val SECRET_KEY = "remoteTrainerApiKey"
    private const val PREFS = "neuron_training"
    private const val STATE_KEY = "state"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var watchJob: Job? = null
    @Volatile private var activeTrainer: RemoteTrainer? = null

    fun loadConfig(ctx: Context): Map<String, Any?> {
        val project = ProjectStore.load(ctx)
        val legacyKey = project.training.remoteTrainerApiKey
        if (legacyKey.isNotBlank()) {
            val secrets = ProjectStore.secrets(ctx)
            if (secrets.get(SECRET_KEY).isNullOrBlank()) secrets.put(SECRET_KEY, legacyKey)
            ProjectStore.save(ctx, project.copy(training = project.training.copy(remoteTrainerApiKey = "")))
        }
        val cfg = ProjectStore.load(ctx).training.copy(remoteTrainerApiKey = "")
        return mapOf(
            "config" to VirtualTree.json.encodeToString(cfg),
            "apiKeyConfigured" to !ProjectStore.secrets(ctx).get(SECRET_KEY).isNullOrBlank(),
        )
    }

    fun saveConfig(ctx: Context, text: String): Map<String, Any> {
        val decoded = VirtualTree.json.decodeFromString<TrainingConfig>(text)
        decoded.validate()
        val secret = ProjectStore.secrets(ctx)
        if (decoded.remoteTrainerApiKey.isNotBlank()) secret.put(SECRET_KEY, decoded.remoteTrainerApiKey.trim())
        val safe = decoded.copy(target = TrainTarget.REMOTE_SERVER, remoteTrainerApiKey = "")
        ProjectStore.save(ctx, ProjectStore.load(ctx).copy(training = safe))
        return mapOf("ok" to true, "apiKeyConfigured" to !secret.get(SECRET_KEY).isNullOrBlank())
    }

    private val GGUF_MAGIC = byteArrayOf('G'.code.toByte(), 'G'.code.toByte(), 'U'.code.toByte(), 'F'.code.toByte())
    /** Operasi yang hasilnya satu berkas GGUF dan diunduh ke HP. MERGE_LORA/MERGE_MODELS menghasilkan folder HF: tidak diunduh. */
    private val GGUF_RESULT_OPS = setOf(ModelOp.QUANTIZE, ModelOp.CONVERT_TO_GGUF, ModelOp.MERGE_LORA_GGUF, ModelOp.SET_GGUF_META)

    private fun modelsRoot(ctx: Context): File = (ctx.getExternalFilesDir("models") ?: File(ctx.filesDir, "models")).apply { mkdirs() }

    private fun opsServer(ctx: Context): Pair<String, String> {
        val url = ProjectStore.load(ctx).training.remoteTrainerUrl.trim()
        require(url.startsWith("https://", true)) { "Atur URL server operasi model dengan HTTPS di halaman Latih terlebih dahulu" }
        return url to (ProjectStore.secrets(ctx).get(SECRET_KEY) ?: "")
    }

    /** Path berkas GGUF milik NeuroN (di bawah folder models, termasuk models/loras) diunggah; selain itu dianggap nama di server. */
    private suspend fun uploadIfLocal(ctx: Context, client: ModelOpsClient, value: String): String {
        val file = File(value)
        if (!file.isFile) return value
        val local = file.canonicalFile
        val root = modelsRoot(ctx).canonicalFile
        require(local.path.startsWith(root.path + File.separator) && local.extension.equals("gguf", true)) { "Pilih model GGUF yang tersimpan di NeuroN" }
        return client.uploadModel(local)
    }

    /** Pesan gagal yang berisi alasan sebenarnya (baris log terakhir server), bukan hanya "[error]". */
    private fun failureMessage(events: List<OpEvent>): String? {
        val failed = events.lastOrNull { it.status == "error" } ?: return null
        val code = failed.raw.opt("code")
        val reason = failed.raw.optString("message")
        val tail = events.filter { it.raw.has("log") }.takeLast(6).joinToString("\n") { it.message }
        return buildString {
            append("Operasi di server gagal")
            if (code != null) append(" (kode $code)")
            if (reason.isNotBlank()) append(": ").append(reason)
            if (tail.isNotBlank()) append("\n").append(tail)
        }
    }

    private suspend fun runOp(client: ModelOpsClient, config: ModelOpsConfig): List<OpEvent> {
        config.validate()
        val events = client.run(config).toList()
        failureMessage(events)?.let { error(it) }
        return events
    }

    /** Unduh GGUF hasil dari server sebagai model baru (model asli tidak diubah). Berkas parsial dihapus bila gagal. */
    private suspend fun downloadGguf(ctx: Context, client: ModelOpsClient, serverName: String): String {
        val safeBase = serverName.substringAfterLast('/').replace(Regex("[^A-Za-z0-9._-]"), "_").removeSuffix(".gguf")
        val target = File(modelsRoot(ctx), "$safeBase-edited-${System.currentTimeMillis()}.gguf")
        try {
            client.download(serverName, target)
            val header = target.inputStream().use { input -> ByteArray(4).also { check(input.read(it) == 4) { "File hasil terlalu pendek" } } }
            check(header.contentEquals(GGUF_MAGIC)) { "Hasil tidak memiliki header GGUF yang valid" }
        } catch (e: Throwable) {
            target.delete()
            throw e
        }
        return target.absolutePath
    }

    fun runModelOperation(ctx: Context, text: String): Map<String, Any?> = runBlocking(Dispatchers.IO) {
        val requested = VirtualTree.json.decodeFromString<ModelOpsConfig>(text)
        requested.validate()
        val (url, key) = opsServer(ctx)
        val client = ModelOpsClient(url, key)
        val config = when (requested.op) {
            ModelOp.QUANTIZE, ModelOp.CONVERT_TO_GGUF, ModelOp.SET_GGUF_META, ModelOp.INSPECT ->
                requested.copy(source = uploadIfLocal(ctx, client, requested.source))
            ModelOp.MERGE_LORA_GGUF -> {
                val base = uploadIfLocal(ctx, client, requested.source)
                val adapter = uploadIfLocal(ctx, client, requested.adapter)
                require(base != adapter) { "Model dasar dan adapter tidak boleh bernama sama" }
                requested.copy(source = base, adapter = adapter)
            }
            else -> requested
        }.copy(serverUrl = url, serverApiKey = key)
        val events = runOp(client, config)
        val output = if (config.op in GGUF_RESULT_OPS) downloadGguf(ctx, client, config.output) else ""
        val result = events.lastOrNull { it.status == "done" && (it.raw.has("meta") || it.raw.has("params") || it.raw.has("files") || it.raw.has("kind")) }
        mapOf(
            "op" to config.op.name,
            "outputPath" to output,
            "serverOutput" to config.output,
            "result" to (result?.raw?.toString() ?: ""),
            "logs" to events.map { it.message },
        )
    }

    /**
     * Gabung beberapa model bobot penuh (rata-rata berbobot, arsitektur sama) di server -> GGUF F16 -> kuantisasi opsional -> unduh ke HP.
     * Hasil antara (folder HF dan GGUF F16, bisa puluhan GB) dihapus dari server; hasil akhir dihapus setelah berhasil diunduh.
     * Bila unduhan gagal, hasil akhir TETAP di server dan namanya disebut di pesan error supaya tidak perlu mengulang dari awal.
     */
    fun runModelPipeline(ctx: Context, text: String): Map<String, Any?> = runBlocking(Dispatchers.IO) {
        val req = JSONObject(text)
        val name = req.getString("name").replace(Regex("[^A-Za-z0-9._-]"), "_").trimStart('.', '-').take(60).ifBlank { "merged" }
        val sources = req.getJSONArray("sources").let { a -> List(a.length()) { a.getString(it).trim() } }
        require(sources.size >= 2 && sources.all { it.isNotBlank() }) { "Isi minimal 2 model" }
        val weights = req.optJSONArray("weights")?.let { a -> List(a.length()) { a.getDouble(it) } } ?: emptyList()
        val quant = req.optString("quant", "Q4_K_M").trim().uppercase().ifBlank { "Q4_K_M" }
        val hfDir = "pipeline/$name-hf"
        val f16 = "pipeline/$name-f16.gguf"
        val finalName = if (quant == "F16") f16 else "outputs/$name-$quant.gguf"
        val (url, key) = opsServer(ctx)
        val client = ModelOpsClient(url, key)
        fun cfg(c: ModelOpsConfig) = c.copy(serverUrl = url, serverApiKey = key)
        val logs = mutableListOf<String>()
        val intermediates = mutableListOf(hfDir).also { if (quant != "F16") it += f16 }
        try {
            logs += "== 1/${if (quant == "F16") 2 else 3}: gabung bobot =="
            logs += runOp(client, cfg(ModelOpsConfig(op = ModelOp.MERGE_MODELS, output = hfDir, mergeSources = sources, mergeWeights = weights))).map { it.message }
            logs += "== 2/${if (quant == "F16") 2 else 3}: konversi ke GGUF F16 =="
            logs += runOp(client, cfg(ModelOpsConfig(op = ModelOp.CONVERT_TO_GGUF, source = hfDir, output = f16, outtype = "f16"))).map { it.message }
            if (quant != "F16") {
                logs += "== 3/3: kuantisasi $quant =="
                logs += runOp(client, cfg(ModelOpsConfig(op = ModelOp.QUANTIZE, source = f16, output = finalName, quantization = quant))).map { it.message }
            }
            val path = try {
                downloadGguf(ctx, client, finalName)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                throw IllegalStateException("Hasil sudah jadi di server ($finalName) tetapi gagal diunduh: ${e.message}", e)
            }
            runCatching { client.deleteModel(finalName) }
            mapOf("op" to "MERGE_PIPELINE", "outputPath" to path, "serverOutput" to finalName, "logs" to logs)
        } finally {
            withContext(NonCancellable) { intermediates.forEach { runCatching { client.deleteModel(it) } } }
        }
    }

    fun inspectDataset(ctx: Context, sourcePath: String, methodName: String): Map<String, Any?> {
        val method = enumValueOf<com.neuron.model.TrainMethod>(methodName)
        val source = File(sourcePath)
        require(source.isFile) { "Berkas dataset tidak ditemukan" }
        require(source.length() <= 256L * 1024 * 1024) { "Dataset maksimal 256 MB" }
        require(source.extension.lowercase() in setOf("jsonl", "json", "csv")) { "Format harus .jsonl, .json, atau .csv" }
        val dir = File(ctx.filesDir, "datasets").apply { mkdirs() }
        val root = dir.canonicalFile
        val original = source.canonicalFile
        val target = if (original.path.startsWith(root.path + File.separator)) {
            original
        } else {
            val safeName = source.name.replace(Regex("[^A-Za-z0-9._-]"), "_")
            File(dir, "${UUID.randomUUID()}_$safeName").also { dest ->
                source.inputStream().use { input -> dest.outputStream().use { output -> input.copyTo(output) } }
            }
        }
        val report = DatasetImporter().inspect(target, method)
        return mapOf(
            "path" to target.absolutePath,
            "format" to report.format,
            "totalRecords" to report.totalRecords,
            "validRecords" to report.validRecords,
            "errorCount" to report.errorCount,
            "ok" to report.ok,
            "errors" to report.errors,
            "preview" to report.preview,
        )
    }

    fun start(ctx: Context): Map<String, Any> {
        val project = ProjectStore.load(ctx)
        val cfg = project.training.copy(remoteTrainerApiKey = ProjectStore.secrets(ctx).get(SECRET_KEY) ?: "")
        cfg.validate()
        require(cfg.learningRate <= 1.0) { "Learning rate maksimal 1" }
        require(cfg.epochs <= 100) { "Epoch maksimal 100" }
        require(cfg.batchSize <= 256) { "Batch size maksimal 256" }
        require(cfg.loraRank <= 1024) { "LoRA rank maksimal 1024" }
        require(cfg.loraAlpha <= 4096) { "LoRA alpha maksimal 4096" }
        require(cfg.target == TrainTarget.REMOTE_SERVER) { "Pilih target remote server" }
        require(cfg.method != com.neuron.model.TrainMethod.RLHF) { "Metode RLHF belum didukung server trainer" }
        require(cfg.baseModel.isNotBlank()) { "Isi ID model dasar, misalnya org/model" }
        require(cfg.remoteTrainerUrl.isNotBlank()) { "Isi URL remote trainer" }
        require(cfg.datasetPath.isNotBlank()) { "Pilih dan validasi dataset terlebih dahulu" }
        val dataset = checkedDataset(ctx, cfg.datasetPath)
        val report = DatasetImporter().inspect(dataset, cfg.method)
        require(report.ok) { "Dataset tidak valid (${report.errorCount} kesalahan); impor ulang dan perbaiki baris yang dilaporkan" }
        val trainer = RemoteTrainer(cfg.remoteTrainerUrl, cfg.remoteTrainerApiKey)
        val remoteCfg = cfg.baseModel.let { raw ->
            val local = File(raw)
            if (local.isFile && local.extension.equals("gguf", true)) {
                val remoteName = runBlocking(Dispatchers.IO) { trainer.uploadModel(local) }
                cfg.copy(baseModel = remoteName)
            } else cfg
        }
        val id = runBlocking(Dispatchers.IO) { trainer.startJob(remoteCfg) }
        activeTrainer = trainer
        putState(ctx, JSONObject().put("jobId", id).put("status", "running").put("step", 0).put("total", 0).put("loss", JSONObject.NULL).put("logs", JSONArray()))
        observe(ctx, trainer, id)
        return mapOf("jobId" to id, "status" to "running")
    }

    fun reconnect(ctx: Context, id: String): Map<String, Any> {
        require(id.matches(Regex("[A-Za-z0-9_-]{1,128}"))) { "ID job tidak valid" }
        val cfg = ProjectStore.load(ctx).training
        require(cfg.remoteTrainerUrl.isNotBlank()) { "URL remote trainer belum diatur" }
        val trainer = RemoteTrainer(cfg.remoteTrainerUrl, ProjectStore.secrets(ctx).get(SECRET_KEY) ?: "")
        trainer.useJob(id)
        activeTrainer = trainer
        putState(ctx, JSONObject().put("jobId", id).put("status", "connecting").put("step", 0).put("total", 0).put("loss", JSONObject.NULL).put("logs", JSONArray()))
        observe(ctx, trainer, id)
        return mapOf("jobId" to id, "status" to "connecting")
    }

    fun state(ctx: Context): Map<String, Any?> {
        val obj = runCatching { JSONObject(ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(STATE_KEY, "{}") ?: "{}") }
            .getOrDefault(JSONObject())
        return mapOf(
            "jobId" to obj.optString("jobId").takeIf { it.isNotEmpty() },
            "status" to obj.optString("status", "idle"),
            "step" to obj.optInt("step"),
            "total" to obj.optInt("total"),
            "loss" to if (obj.isNull("loss")) null else obj.optDouble("loss"),
            "logs" to (0 until obj.optJSONArray("logs").let { it?.length() ?: 0 }).map { obj.optJSONArray("logs")!!.optString(it) },
            "adapterPath" to obj.optString("adapterPath").takeIf { it.isNotEmpty() },
            "error" to obj.optString("error").takeIf { it.isNotEmpty() },
        )
    }

    fun cancel(ctx: Context, id: String): Map<String, Any> {
        require(id.matches(Regex("[A-Za-z0-9_-]{1,128}"))) { "ID job tidak valid" }
        val trainer = activeTrainer?.also { it.useJob(id) } ?: RemoteTrainer(
            ProjectStore.load(ctx).training.remoteTrainerUrl,
            ProjectStore.secrets(ctx).get(SECRET_KEY) ?: "",
        ).also { it.useJob(id) }
        runBlocking(Dispatchers.IO) { trainer.cancel() }
        val current = readState(ctx).put("status", "cancelled")
        putState(ctx, current)
        return mapOf("ok" to true)
    }

    fun downloadAdapter(ctx: Context, id: String, gguf: Boolean): Map<String, Any?> {
        require(id.matches(Regex("[A-Za-z0-9_-]{1,128}"))) { "ID job tidak valid" }
        val current = readState(ctx)
        require(current.optString("jobId") == id && current.optString("status") == "done") { "Adapter hanya dapat diunduh setelah job selesai" }
        val cfg = ProjectStore.load(ctx).training
        require(cfg.remoteTrainerUrl.isNotBlank()) { "URL remote trainer belum diatur" }
        require(!gguf || cfg.method in setOf(com.neuron.model.TrainMethod.LORA, com.neuron.model.TrainMethod.QLORA)) { "Konversi GGUF hanya tersedia untuk adapter LoRA/QLoRA" }
        val trainer = RemoteTrainer(cfg.remoteTrainerUrl, ProjectStore.secrets(ctx).get(SECRET_KEY) ?: "").also { it.useJob(id) }
        // LoRA GGUF disimpan di folder LoRA (bukan folder model dasar) supaya tidak tercampur di daftar model.
        val folder = if (gguf) LoraBridge.dir(ctx)
            else (ctx.getExternalFilesDir("adapters") ?: File(ctx.filesDir, "adapters")).apply { mkdirs() }
        val file = File(folder, if (gguf) "$id-lora.gguf" else "$id.zip")
        runBlocking(Dispatchers.IO) { trainer.downloadAdapter(file, gguf) }
        val state = readState(ctx).put("adapterPath", file.absolutePath)
        putState(ctx, state)
        if (!gguf) return mapOf("path" to file.absolutePath, "gguf" to false)
        // Dipasang hanya bila cocok dengan model aktif; bila tidak, berkas tetap tersimpan dan alasannya dikembalikan.
        return mapOf("path" to file.absolutePath, "gguf" to true) + LoraBridge.attachDownloaded(ctx, file)
    }

    private fun observe(ctx: Context, trainer: RemoteTrainer, id: String) {
        watchJob?.cancel()
        watchJob = scope.launch {
            try {
                trainer.watch(id).collect { p -> updateProgress(ctx, id, p) }
                val current = readState(ctx)
                if (current.optString("status") !in setOf("done", "error", "cancelled")) {
                    current.put("status", "done")
                    putState(ctx, current)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val current = readState(ctx).put("status", "error").put("error", e.message ?: "Gagal memantau job")
                appendLog(current, "ERROR: ${e.message ?: e.javaClass.simpleName}")
                putState(ctx, current)
            }
        }
    }

    private fun updateProgress(ctx: Context, id: String, p: TrainProgress) {
        val state = readState(ctx).put("jobId", id).put("step", p.step).put("total", p.totalSteps)
        if (!p.loss.isNaN() && p.loss.isFinite()) state.put("loss", p.loss.toDouble())
        p.log.takeIf { it.isNotBlank() }?.let { appendLog(state, it) }
        when (p.status) {
            "done", "saved" -> state.put("status", "done")
            "error" -> state.put("status", "error")
            else -> if (state.optString("status") == "connecting") state.put("status", "running")
        }
        if (p.status == "error") state.put("error", p.log.ifBlank { "Training gagal" })
        putState(ctx, state)
    }

    private fun appendLog(state: JSONObject, line: String) {
        val logs = state.optJSONArray("logs") ?: JSONArray()
        logs.put(line.take(1200))
        while (logs.length() > 300) logs.remove(0)
        state.put("logs", logs)
    }

    private fun checkedDataset(ctx: Context, path: String): File {
        val root = File(ctx.filesDir, "datasets").canonicalFile
        val file = File(path).canonicalFile
        require(file.isFile && file.path.startsWith(root.path + File.separator)) { "Dataset harus diimpor melalui pemilih berkas" }
        return file
    }

    private fun readState(ctx: Context): JSONObject = runCatching {
        JSONObject(ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(STATE_KEY, "{}") ?: "{}")
    }.getOrDefault(JSONObject())

    private fun putState(ctx: Context, value: JSONObject) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(STATE_KEY, value.toString()).apply()
    }
}
