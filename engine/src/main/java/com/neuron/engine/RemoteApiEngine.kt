package com.neuron.engine

import com.neuron.model.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Engine API OpenAI-compatible (OpenAI, OpenRouter, Ollama, llama-server, HP lain). Juga dipakai Copilot. */
class RemoteApiEngine(private val cfg: EngineConfig) : InferenceEngine {
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .build()
    private val base = cfg.baseUrl.trim().trimEnd('/').removeSuffix("/v1")
    private val isOpenAi = base.contains("openai.com")

    @Volatile override var lastStats: GenStats? = null
        private set

    private fun request(path: String, body: JSONObject): Request = Request.Builder()
        .url("$base$path")
        .apply { if (cfg.apiKey.isNotBlank()) header("Authorization", "Bearer ${cfg.apiKey}") }
        .post(body.toString().toRequestBody("application/json".toMediaType()))
        .build()

    override suspend fun load(project: AiProject) {}

    override fun chat(messages: List<ChatMessage>, params: ChatParams): Flow<String> = flow {
        val body = JSONObject().apply {
            put("model", cfg.model); put("stream", true)
            put("stream_options", JSONObject().put("include_usage", true))   // chunk terakhir membawa jumlah token
            put("messages", JSONArray().apply {
                if (params.systemPrompt.isNotBlank()) put(JSONObject().put("role", "system").put("content", params.systemPrompt))
                messages.forEach { m ->
                    val content: Any = if (m.images.isEmpty()) m.content else JSONArray().apply {
                        put(JSONObject().put("type", "text").put("text", m.content))
                        m.images.forEach { url ->
                            put(JSONObject().put("type", "image_url").put("image_url", JSONObject().put("url", url)))
                        }
                    }
                    put(JSONObject().put("role", m.role).put("content", content))
                }
            })
            put("temperature", params.temperature.toDouble()); put("top_p", params.topP.toDouble())
            put("max_tokens", params.maxTokens)
            if (params.presencePenalty != 0f) put("presence_penalty", params.presencePenalty.toDouble())
            if (params.frequencyPenalty != 0f) put("frequency_penalty", params.frequencyPenalty.toDouble())
            if (params.stopSequences.isNotEmpty()) put("stop", JSONArray(if (isOpenAi) params.stopSequences.take(4) else params.stopSequences))   // OpenAI maks 4
            if (params.seed >= 0) put("seed", params.seed)
            if (!isOpenAi) {   // parameter ekstra didukung Ollama / llama-server / vLLM
                put("top_k", params.topK); put("min_p", params.minP.toDouble()); put("repeat_penalty", params.repeatPenalty.toDouble())
            }
        }
        val t0 = System.nanoTime()
        var chunks = 0                      // cadangan bila server tidak mengirim usage: 1 chunk ~ 1 token
        var promptTokens = 0; var completionTokens = -1
        val call = http.newCall(request("/v1/chat/completions", body))
        val h = currentCoroutineContext()[Job]?.invokeOnCompletion { call.cancel() }
        try {
            call.execute().use { r ->
                if (!r.isSuccessful) throw IOException("HTTP ${r.code}: ${r.body?.string()?.take(300)}")
                val src = r.body!!.source()
                while (!src.exhausted()) {
                    val line = src.readUtf8Line() ?: break
                    if (!line.startsWith("data:")) continue
                    val data = line.removePrefix("data:").trim()
                    if (data == "[DONE]") break
                    val obj = JSONObject(data)
                    obj.optJSONObject("error")?.let { throw IOException(it.optString("message", "error dari server")) }
                    obj.optJSONObject("usage")?.let { u ->
                        promptTokens = u.optInt("prompt_tokens", 0)
                        completionTokens = u.optInt("completion_tokens", -1)
                    }
                    val choices = obj.optJSONArray("choices") ?: continue
                    if (choices.length() == 0) continue   // chunk usage: choices kosong
                    val delta = choices.getJSONObject(0).optJSONObject("delta") ?: continue
                    // org.json mengubah JSON null menjadi teks "null" lewat optString: cek isNull dulu.
                    // reasoning_content (DeepSeek/Qwen thinking) sengaja tidak ditampilkan sebagai jawaban.
                    val text = if (delta.isNull("content")) "" else delta.optString("content", "")
                    if (text.isNotEmpty()) { chunks++; emit(text) }
                }
            }
        } finally {
            h?.dispose()
            lastStats = GenStats(promptTokens, if (completionTokens >= 0) completionTokens else chunks, (System.nanoTime() - t0) / 1_000_000)
        }
    }.flowOn(Dispatchers.IO)

    /** Jalan di Dispatchers.IO (execute() memblokir; di main thread Android akan NetworkOnMainThreadException) dan bisa dibatalkan. */
    override suspend fun embed(text: String): FloatArray = withContext(Dispatchers.IO) {
        val body = JSONObject().put("model", cfg.model).put("input", text)
        val call = http.newCall(request("/v1/embeddings", body))
        val h = currentCoroutineContext()[Job]?.invokeOnCompletion { call.cancel() }
        try {
            call.execute().use { r ->
                if (!r.isSuccessful) throw IOException("HTTP ${r.code}: ${r.body?.string()?.take(300)}")
                val data = JSONObject(r.body!!.string()).optJSONArray("data")
                if (data == null || data.length() == 0) throw IOException("Server tidak mengembalikan embedding (model '${cfg.model}' mungkin bukan model embedding)")
                val arr = data.getJSONObject(0).getJSONArray("embedding")
                FloatArray(arr.length()) { arr.getDouble(it).toFloat() }
            }
        } finally { h?.dispose() }
    }
    override suspend fun unload() {}
}
