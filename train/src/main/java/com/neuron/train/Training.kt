package com.neuron.train

import com.neuron.model.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Satu event progres. loss = NaN bila event tidak membawa loss (mis. eval_loss, status). */
data class TrainProgress(val step: Int, val totalSteps: Int, val loss: Float, val log: String = "", val status: String? = null)

interface Trainer {
    fun train(cfg: TrainingConfig, project: AiProject): Flow<TrainProgress>
    suspend fun cancel()
}

/**
 * Klien untuk python/server.py (NeuroN Trainer).
 * Alur: unggah dataset (train & val) -> POST /train -> ikuti progres lewat SSE.
 * Training berat dilakukan di server Python, bukan di dalam APK.
 */
class RemoteTrainer(baseUrl: String, private val apiKey: String = "") : Trainer {
    private val base = baseUrl.trim().trimEnd('/')
    private val http = OkHttpClient.Builder().readTimeout(0, TimeUnit.SECONDS).build()
    @Volatile var jobId: String? = null; private set

    private fun req(path: String) = Request.Builder().url("$base$path").apply { if (apiKey.isNotBlank()) header("X-API-Key", apiKey) }

    suspend fun uploadDataset(file: File, remoteName: String = file.name): String = withContext(Dispatchers.IO) {
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("file", remoteName, file.asRequestBody("application/octet-stream".toMediaType())).build()
        http.newCall(req("/datasets").post(body).build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("Upload gagal: HTTP ${r.code}")
            JSONObject(r.body!!.string()).getString("name")
        }
    }

    /** Uploads data and creates the remote job, returning its ID before progress observation. */
    suspend fun startJob(cfg: TrainingConfig): String = withContext(Dispatchers.IO) {
        require(base.startsWith("http://") || base.startsWith("https://")) { "URL trainer harus memakai http:// atau https://" }
        require(cfg.method != TrainMethod.RLHF) { "Metode RLHF belum didukung server trainer" }
        val trainFile = File(cfg.datasetPath)
        require(trainFile.isFile) { "Berkas dataset train tidak ditemukan" }
        val name = uploadDataset(trainFile, remoteName = "${trainFile.parentFile?.name ?: "ds"}_${trainFile.name}")
        val valName = cfg.valDatasetPath.takeIf { it.isNotBlank() }?.let { vp ->
            val vf = File(vp)
            require(vf.isFile) { "Berkas dataset validasi tidak ditemukan" }
            uploadDataset(vf, remoteName = "${vf.parentFile?.name ?: "ds"}_${vf.name}")
        }
        val json = JSONObject().put("method", cfg.method.name).put("base_model", cfg.baseModel)
            .put("dataset", name).put("val_dataset", valName ?: "")
            .put("learning_rate", cfg.learningRate).put("epochs", cfg.epochs).put("batch_size", cfg.batchSize)
            .put("lora_rank", cfg.loraRank).put("lora_alpha", cfg.loraAlpha)
        val id = http.newCall(req("/train").post(json.toString().toRequestBody("application/json".toMediaType())).build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("Mulai training gagal: HTTP ${r.code} ${r.body?.string()?.take(200)}")
            JSONObject(r.body!!.string()).getString("job_id")
        }
        jobId = id
        id
    }

    override fun train(cfg: TrainingConfig, project: AiProject): Flow<TrainProgress> = flow {
        emitAll(watch(startJob(cfg)))
    }.flowOn(Dispatchers.IO)

    /**
     * Ikuti progres sebuah job. Dipakai juga untuk menyambung job yang sudah berjalan (mis. setelah app dibuka ulang).
     * Berhenti memantau saat collector dibatalkan; training tetap berjalan di server.
     */
    fun watch(id: String): Flow<TrainProgress> = flow {
        jobId = id
        val call = http.newCall(req("/train/$id/events").get().build())
        val h = currentCoroutineContext()[Job]?.invokeOnCompletion { call.cancel() }
        try {
            call.execute().use { r ->
                if (!r.isSuccessful) throw IOException("Ikuti progres gagal: HTTP ${r.code}")
                val src = r.body!!.source()
                while (!src.exhausted()) {
                    val line = src.readUtf8Line() ?: break
                    if (!line.startsWith("data:")) continue
                    val o = JSONObject(line.removePrefix("data:").trim())
                    emit(
                        TrainProgress(
                            o.optInt("step"),
                            o.optInt("total"),
                            if (o.has("loss")) o.optDouble("loss").toFloat() else Float.NaN,
                            o.optString("log", o.optString("message", "")),
                            o.optString("status").ifEmpty { null },
                        )
                    )
                    if (o.optString("status") in listOf("done", "error")) break
                }
            }
        } finally { h?.dispose() }
    }.flowOn(Dispatchers.IO)

    /** Pilih job yang sudah ada (mis. setelah app dibuka ulang) untuk diunduh. */
    fun useJob(id: String) { jobId = id }

    override suspend fun cancel() = withContext(Dispatchers.IO) {
        jobId?.let { id ->
            http.newCall(req("/train/$id/cancel").post("".toRequestBody()).build()).execute().use { response ->
                if (!response.isSuccessful) throw IOException("Pembatalan gagal: HTTP ${response.code} ${response.body?.string()?.take(200)}")
            }
        }
        Unit
    }

    /** Unduh adapter (zip) atau LoRA .gguf (gguf = true; server perlu LLAMA_CPP_DIR). */
    suspend fun downloadAdapter(dest: File, gguf: Boolean = false) = withContext(Dispatchers.IO) {
        val id = jobId ?: error("Belum ada job")
        val r0 = if (gguf) req("/convert/lora/$id").post("".toRequestBody()) else req("/adapters/$id").get()
        http.newCall(r0.build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("HTTP ${r.code}")
            dest.outputStream().use { o -> r.body!!.byteStream().copyTo(o) }
        }
    }
}
