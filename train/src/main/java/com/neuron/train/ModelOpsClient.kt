package com.neuron.train

import com.neuron.model.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okio.Buffer
import okio.BufferedSink
import okio.source
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.concurrent.TimeUnit

data class OpEvent(val status: String?, val message: String, val raw: JSONObject)

/** Klien operasi model ke python/server.py. Upload/unduh di-stream (tanpa batas ukuran, bisa dilanjutkan). */
class ModelOpsClient(baseUrl: String, private val apiKey: String = "") {
    private val base = baseUrl.trim().trimEnd('/')
    private val http = OkHttpClient.Builder().readTimeout(0, TimeUnit.SECONDS).writeTimeout(0, TimeUnit.SECONDS).build()
    private fun req(path: String) = Request.Builder().url("$base$path").apply { if (apiKey.isNotBlank()) header("X-API-Key", apiKey) }

    private class ProgressBody(val file: File, val cb: (Long, Long) -> Unit) : RequestBody() {
        override fun contentType() = "application/octet-stream".toMediaType()
        override fun contentLength() = file.length()
        override fun writeTo(sink: BufferedSink) {
            file.source().use { src ->
                val buf = Buffer(); var done = 0L
                while (true) { val n = src.read(buf, 65536); if (n < 0) break; sink.write(buf, n); done += n; cb(done, file.length()) }
            }
        }
    }

    suspend fun uploadModel(file: File, onProgress: (Long, Long) -> Unit = { _, _ -> }): String = withContext(Dispatchers.IO) {
        val body = MultipartBody.Builder().setType(MultipartBody.FORM).addFormDataPart("file", file.name, ProgressBody(file, onProgress)).build()
        http.newCall(req("/models").post(body).build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("Upload gagal: HTTP ${r.code}")
            JSONObject(r.body!!.string()).getString("name")
        }
    }

    suspend fun listModels(): List<Triple<String, Boolean, Long>> = withContext(Dispatchers.IO) {
        http.newCall(req("/models").get().build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("HTTP ${r.code}")
            val a = JSONArray(r.body!!.string())
            List(a.length()) { val o = a.getJSONObject(it); Triple(o.getString("name"), o.getBoolean("dir"), o.getLong("bytes")) }
        }
    }

    /** Unduh file model dari server; jika dest sudah ada sebagian, dilanjutkan (HTTP Range). */
    suspend fun download(name: String, dest: File, onProgress: (Long, Long) -> Unit = { _, _ -> }) = withContext(Dispatchers.IO) {
        val start = if (dest.exists()) dest.length() else 0L
        val b = req("/models/$name").get().apply { if (start > 0) header("Range", "bytes=$start-") }
        http.newCall(b.build()).execute().use { r ->
            if (r.code == 416) return@use                       // sudah lengkap
            if (!r.isSuccessful) throw IOException("HTTP ${r.code}")
            val resumed = r.code == 206
            val total = (if (resumed) start else 0L) + r.body!!.contentLength()
            RandomAccessFile(dest, "rw").use { raf ->
                if (resumed) raf.seek(start) else raf.setLength(0)
                var done = if (resumed) start else 0L
                val buf = ByteArray(1 shl 16)
                r.body!!.byteStream().use { ins -> while (true) { val n = ins.read(buf); if (n < 0) break; raf.write(buf, 0, n); done += n; onProgress(done, total) } }
            }
        }
    }

    fun run(c: ModelOpsConfig): Flow<OpEvent> = flow {
        val params = JSONObject().put("source", c.source).put("output", c.output).put("quant", c.quantization)
            .put("outtype", c.outtype).put("adapter", c.adapter).put("key", c.metaKey).put("value", c.metaValue)
            .put("sources", JSONArray(c.mergeSources)).put("weights", JSONArray(c.mergeWeights))
        val body = JSONObject().put("op", c.op.name).put("params", params)
        val id = http.newCall(req("/ops").post(body.toString().toRequestBody("application/json".toMediaType())).build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("HTTP ${r.code}: ${r.body?.string()?.take(300)}")
            JSONObject(r.body!!.string()).getString("job_id")
        }
        emit(OpEvent(null, "job $id dimulai", JSONObject()))
        val call = http.newCall(req("/jobs/$id/events").get().build())
        val h = currentCoroutineContext()[Job]?.invokeOnCompletion { call.cancel() }
        try {
            call.execute().use { r ->
                val src = r.body!!.source()
                while (!src.exhausted()) {
                    val line = src.readUtf8Line() ?: break
                    if (!line.startsWith("data:")) continue
                    val o = JSONObject(line.removePrefix("data:").trim())
                    val st = o.optString("status").ifEmpty { null }
                    val msg = when {
                        o.has("log") -> o.getString("log")
                        o.has("meta") || o.has("params") || o.has("files") -> o.toString(2)
                        st != null -> "[$st] " + o.optString("path", o.optString("message", ""))
                        else -> o.toString()
                    }
                    emit(OpEvent(st, msg, o))
                    if (st == "done" && (o.has("meta") || o.has("params") || o.has("path"))) break   // hasil operasi
                    if (st == "error") break
                }
            }
        } finally { h?.dispose() }
    }.flowOn(Dispatchers.IO)
}
