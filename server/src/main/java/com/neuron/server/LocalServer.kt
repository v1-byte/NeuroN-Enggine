package com.neuron.server

import com.neuron.engine.ChatMessage
import com.neuron.engine.EngineFactory
import com.neuron.engine.EngineHub
import com.neuron.engine.InferenceEngine
import com.neuron.engine.ModelDefaults
import com.neuron.model.AiProject
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.cio.*
import io.ktor.server.engine.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.util.UUID

private val oaiJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

@Serializable data class OaiMsg(val role: String = "user", val content: JsonElement? = null)
@Serializable data class OaiChatReq(
    val model: String? = null,
    val messages: List<OaiMsg> = emptyList(),
    val temperature: Float? = null,
    val top_p: Float? = null,
    val max_tokens: Int? = null,
    val stream: Boolean = false,
    val stop: JsonElement? = null,
)
@Serializable data class OaiRespMsg(val role: String, val content: String)
@Serializable data class OaiChoice(val index: Int, val message: OaiRespMsg, @SerialName("finish_reason") val finishReason: String)
@Serializable data class OaiUsage(@SerialName("prompt_tokens") val promptTokens: Int = 0, @SerialName("completion_tokens") val completionTokens: Int = 0, @SerialName("total_tokens") val totalTokens: Int = 0)
@Serializable data class OaiChatResp(val id: String, @SerialName("object") val obj: String, val created: Long, val model: String, val choices: List<OaiChoice>, val usage: OaiUsage = OaiUsage())
@Serializable data class OaiDelta(val role: String? = null, val content: String? = null)
@Serializable data class OaiChunkChoice(val index: Int, val delta: OaiDelta, @SerialName("finish_reason") val finishReason: String? = null)
@Serializable data class OaiChunk(val id: String, @SerialName("object") val obj: String, val created: Long, val model: String, val choices: List<OaiChunkChoice>)
@Serializable data class OaiEmbReq(val model: String? = null, val input: JsonElement? = null)
@Serializable data class OaiEmbItem(val index: Int, val embedding: List<Float>, @SerialName("object") val obj: String = "embedding")
@Serializable data class OaiEmbResp(@SerialName("object") val obj: String = "list", val data: List<OaiEmbItem>, val model: String)
@Serializable data class OaiModel(val id: String, @SerialName("object") val obj: String = "model", @SerialName("owned_by") val ownedBy: String = "neuron")
@Serializable data class OaiModelList(@SerialName("object") val obj: String = "list", val data: List<OaiModel>)
@Serializable data class OaiErrDetail(val message: String, val type: String)
@Serializable data class OaiErr(val error: OaiErrDetail)

/** content bisa string atau daftar bagian [{type:"text",text:..}] (format OpenAI). */
private fun JsonElement?.asText(): String = when (this) {
    null, JsonNull -> ""
    is JsonPrimitive -> this.content
    is JsonArray -> this.joinToString("") { part -> ((part as? JsonObject)?.get("text") as? JsonPrimitive)?.contentOrNull ?: "" }
    else -> this.toString()
}

/** stop bisa string atau daftar string. */
private fun JsonElement?.stops(): List<String> = when (this) {
    null, JsonNull -> emptyList()
    is JsonPrimitive -> listOf(this.content)
    is JsonArray -> this.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
    else -> emptyList()
}

/**
 * Server OpenAI-compatible di HP.
 *  GET  /health              -> status
 *  GET  /v1/models           -> daftar model (satu: "local")
 *  POST /v1/chat/completions -> non-stream, atau stream=true (SSE, diakhiri data: [DONE])
 *  POST /v1/embeddings       -> vektor dari engine yang sama
 * Semua route (kecuali /health) memerlukan "Authorization: Bearer <apiKey>" dan apiKey WAJIB (server menolak dibuat tanpa kunci).
 * Satu generate pada satu waktu: permintaan lain menunggu di EngineHub.gate.
 */
class LocalServer(
    private val projectProvider: () -> AiProject,
    private val apiKey: String? = null,
    private val port: Int = 8080,
) {
    companion object { const val MODEL_ID = "local" }

    init { require(!apiKey.isNullOrBlank()) { "API key wajib diisi" } }

    private var server: EmbeddedServer<*, *>? = null

    fun start() {
        server = embeddedServer(CIO, port = port, host = "0.0.0.0") { module() }.also { it.start(wait = false) }
    }

    fun stop() {
        server?.stop(500, 1000)
        server = null
    }

    private fun authorized(call: ApplicationCall) =
        java.security.MessageDigest.isEqual(
            (call.request.headers[HttpHeaders.Authorization] ?: "").toByteArray(),
            "Bearer $apiKey".toByteArray(),
        )

    private fun Application.module() {
        routing {
            get("/health") { call.respondText("{\"status\":\"ok\"}", ContentType.Application.Json) }

            get("/v1/models") {
                if (!authorized(call)) return@get call.sendError(HttpStatusCode.Unauthorized, "API key tidak valid")
                call.sendJson(HttpStatusCode.OK, OaiModelList(data = listOf(OaiModel(MODEL_ID))))
            }

            post("/v1/chat/completions") { chat(call) }
            post("/v1/embeddings") { embeddings(call) }
        }
    }

    private suspend fun chat(call: ApplicationCall) {
        if (!authorized(call)) return call.sendError(HttpStatusCode.Unauthorized, "API key tidak valid")
        val req = try {
            oaiJson.decodeFromString<OaiChatReq>(call.receiveText())
        } catch (e: Exception) {
            return call.sendError(HttpStatusCode.BadRequest, "JSON tidak valid: ${e.message}")
        }
        val messages = req.messages.map { ChatMessage(it.role, it.content.asText()) }
        if (messages.isEmpty()) return call.sendError(HttpStatusCode.BadRequest, "messages kosong")

        val project = projectProvider()
        val base = ModelDefaults.effective(project)
        val params = base.copy(
            temperature = req.temperature ?: base.temperature,
            topP = req.top_p ?: base.topP,
            maxTokens = req.max_tokens ?: base.maxTokens,
            stopSequences = base.stopSequences + req.stop.stops(),
        )
        val raw = loadOrReply(call, project) ?: return
        // Guardrail & tool calling ikut berlaku untuk API, sama seperti di chat uji.
        val engine = EngineFactory.wrap(raw, project)
        val id = "chatcmpl-${UUID.randomUUID()}"
        val created = System.currentTimeMillis() / 1000

        if (req.stream) {
            call.respondTextWriter(contentType = ContentType.Text.EventStream) {
                suspend fun emit(delta: OaiDelta, finish: String?) {
                    val payload = oaiJson.encodeToString(
                        OaiChunk(id, "chat.completion.chunk", created, MODEL_ID, listOf(OaiChunkChoice(0, delta, finish)))
                    )
                    write("data: $payload\n\n")
                    flush()
                }
                try {
                    EngineHub.gate.withLock {
                        emit(OaiDelta(role = "assistant", content = ""), null)
                        engine.chat(messages, params).collect { tok -> emit(OaiDelta(content = tok), null) }
                    }
                    emit(OaiDelta(), "stop")
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    write("data: ${oaiJson.encodeToString(OaiErr(OaiErrDetail(e.message ?: "gagal generate", "server_error")))}\n\n")
                    flush()
                }
                write("data: [DONE]\n\n")
                flush()
            }
        } else {
            val (text, stats) = try {
                EngineHub.gate.withLock { engine.chat(messages, params).toList().joinToString("") to engine.lastStats }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                return call.sendError(HttpStatusCode.InternalServerError, e.message ?: "gagal generate")
            }
            call.sendJson(
                HttpStatusCode.OK,
                OaiChatResp(
                    id, "chat.completion", created, MODEL_ID,
                    listOf(OaiChoice(0, OaiRespMsg("assistant", text), if (stats != null && stats.completionTokens >= params.maxTokens) "length" else "stop")),
                    OaiUsage(stats?.promptTokens ?: 0, stats?.completionTokens ?: 0, (stats?.promptTokens ?: 0) + (stats?.completionTokens ?: 0)),
                ),
            )
        }
    }

    private suspend fun embeddings(call: ApplicationCall) {
        if (!authorized(call)) return call.sendError(HttpStatusCode.Unauthorized, "API key tidak valid")
        val req = try {
            oaiJson.decodeFromString<OaiEmbReq>(call.receiveText())
        } catch (e: Exception) {
            return call.sendError(HttpStatusCode.BadRequest, "JSON tidak valid: ${e.message}")
        }
        val inputs: List<String> = when (val i = req.input) {
            null, JsonNull -> emptyList()
            is JsonPrimitive -> listOf(i.content)
            is JsonArray -> i.map { (it as? JsonPrimitive)?.content ?: "" }
            else -> emptyList()
        }
        if (inputs.isEmpty()) return call.sendError(HttpStatusCode.BadRequest, "input kosong")
        val engine = loadOrReply(call, projectProvider()) ?: return
        val data = try {
            EngineHub.gate.withLock { inputs.mapIndexed { idx, s -> OaiEmbItem(idx, engine.embed(s).toList()) } }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return call.sendError(HttpStatusCode.InternalServerError, e.message ?: "gagal embed")
        }
        call.sendJson(HttpStatusCode.OK, OaiEmbResp(data = data, model = MODEL_ID))
    }

    /** Muat model bila perlu. Jika gagal, balas 503 dan kembalikan null. */
    private suspend fun loadOrReply(call: ApplicationCall, project: AiProject): InferenceEngine? =
        try {
            EngineHub.ensure(project)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            call.sendError(HttpStatusCode.ServiceUnavailable, "Model belum siap: ${e.message}")
            null
        }

    private suspend inline fun <reified T> ApplicationCall.sendJson(status: HttpStatusCode, body: T) =
        respondText(oaiJson.encodeToString(body), ContentType.Application.Json, status)

    private suspend fun ApplicationCall.sendError(status: HttpStatusCode, msg: String) =
        sendJson(
            status,
            OaiErr(OaiErrDetail(msg, if (status == HttpStatusCode.Unauthorized) "authentication_error" else "invalid_request_error")),
        )
}
