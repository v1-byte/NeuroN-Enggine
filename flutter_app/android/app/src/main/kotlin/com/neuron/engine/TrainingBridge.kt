package com.neuron.engine

import android.content.Context
import com.neuron.model.LoraInfo
import com.neuron.model.TrainTarget
import com.neuron.model.TrainingConfig
import com.neuron.model.validate
import com.neuron.project.VirtualTree
import com.neuron.train.DatasetImporter
import com.neuron.train.RemoteTrainer
import com.neuron.train.TrainProgress
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
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
        val id = runBlocking(Dispatchers.IO) { trainer.startJob(cfg) }
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

    fun downloadAdapter(ctx: Context, id: String, gguf: Boolean): Map<String, Any> {
        require(id.matches(Regex("[A-Za-z0-9_-]{1,128}"))) { "ID job tidak valid" }
        val current = readState(ctx)
        require(current.optString("jobId") == id && current.optString("status") == "done") { "Adapter hanya dapat diunduh setelah job selesai" }
        val cfg = ProjectStore.load(ctx).training
        require(cfg.remoteTrainerUrl.isNotBlank()) { "URL remote trainer belum diatur" }
        require(!gguf || cfg.method in setOf(com.neuron.model.TrainMethod.LORA, com.neuron.model.TrainMethod.QLORA)) { "Konversi GGUF hanya tersedia untuk adapter LoRA/QLoRA" }
        val trainer = RemoteTrainer(cfg.remoteTrainerUrl, ProjectStore.secrets(ctx).get(SECRET_KEY) ?: "").also { it.useJob(id) }
        val folderName = if (gguf) "models" else "adapters"
        val folder = (ctx.getExternalFilesDir(folderName) ?: File(ctx.filesDir, folderName)).apply { mkdirs() }
        val file = File(folder, if (gguf) "$id-lora.gguf" else "$id.zip")
        runBlocking(Dispatchers.IO) { trainer.downloadAdapter(file, gguf) }
        if (gguf) {
            val project = ProjectStore.load(ctx)
            val text = VirtualTree.json.encodeToString(LoraInfo(file.absolutePath, 1f))
            val updated = VirtualTree.write(project, "model/lora.json", text).getOrThrow()
            ProjectStore.save(ctx, updated)
        }
        val state = readState(ctx).put("adapterPath", file.absolutePath)
        putState(ctx, state)
        return mapOf("path" to file.absolutePath, "gguf" to gguf)
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
