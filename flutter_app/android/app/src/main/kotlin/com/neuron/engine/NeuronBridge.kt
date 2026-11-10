package com.neuron.engine

import android.content.Context
import com.neuron.model.ChatParams
import com.neuron.model.EngineMode
import com.neuron.rag.FileParser
import com.neuron.rag.RagPipeline
import com.neuron.rag.RagPrompt
import com.neuron.rag.SqliteVectorStore
import java.io.File
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Jembatan Flutter <-> engine Kotlin (jalur A di docs/MIGRASI_FLUTTER.md bagian 5).
 *  - "neuron/project" (ProjectBridge.kt): berkas proyek, pengaturan API, fitur.
 *  - "neuron/chat" (EventChannel): stream token. Argumen hanya riwayat pesan; engine dan parameter
 *    dibaca dari proyek yang tersimpan, jadi Dart tidak membawa kunci API. Membatalkan langganan = membatalkan HTTP.
 */
object NeuronBridge {
    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        ProjectBridge.register(messenger, app)
        EventChannel(messenger, "neuron/chat").setStreamHandler(ChatStream(app))
    }
}

/** Satu langganan = satu permintaan chat. Token dikirim ke Dart di thread utama. */
private class ChatStream(private val ctx: Context) : EventChannel.StreamHandler {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var job: Job? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val a = arguments as? Map<*, *>
        if (a == null) {
            events.error("BAD_ARGS", "argumen chat tidak valid", null)
            events.endOfStream()
            return
        }
        val messages = (a["messages"] as? List<*> ?: emptyList<Any>()).mapNotNull { item ->
            val m = item as? Map<*, *> ?: return@mapNotNull null
            ChatMessage(m["role"] as? String ?: "user", m["content"] as? String ?: "")
        }

        job?.cancel()
        job = scope.launch {
            try {
                val (engine, params, project) = withContext(Dispatchers.IO) { prepare() }
                val contextual = withContext(Dispatchers.IO) { addKnowledgeContext(messages, project, engine) }
                engine.chat(contextual, params).collect { token -> events.success(token) }
                events.endOfStream()
            } catch (e: CancellationException) {
                throw e   // dibatalkan dari Dart: tidak perlu melapor
            } catch (e: Throwable) {
                events.error("CHAT_ERROR", e.message ?: e.javaClass.simpleName, null)
                events.endOfStream()
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        job?.cancel()
        job = null
    }

    /** Engine (dengan fitur tools/guardrail dari proyek) dan parameter chat dari chat/params.json yang tersimpan. */
    private suspend fun prepare(): Triple<InferenceEngine, ChatParams, com.neuron.model.AiProject> {
        val p = ProjectStore.load(ctx)
        val key = ProjectStore.secrets(ctx).get(ProjectStore.API_KEY) ?: ""
        val withKey = p.copy(engine = p.engine.copy(apiKey = key))
        if (withKey.engine.mode == EngineMode.API) {
            require(withKey.engine.baseUrl.isNotBlank() && withKey.engine.model.isNotBlank()) { "Atur Base URL dan model di Pengaturan" }
        }
        val raw = EngineHub.ensure(withKey)
        return Triple(EngineFactory.wrap(raw, withKey), ModelDefaults.effective(withKey), withKey)
    }

    private suspend fun addKnowledgeContext(
        messages: List<ChatMessage>,
        project: com.neuron.model.AiProject,
        engine: InferenceEngine,
    ): List<ChatMessage> {
        if (!project.knowledge.ragEnabled || messages.isEmpty()) return messages
        val index = messages.indexOfLast { it.role == "user" }
        if (index < 0) return messages
        val store = SqliteVectorStore(ctx, File(ctx.filesDir, "rag/knowledge.db"))
        if (store.count() == 0) return messages
        val parser = FileParser(ctx)
        val pipeline = RagPipeline(engine, store, project.knowledge, parser,
            "${project.engine.mode}:${project.files.modelPath}:${project.engine.model}")
        val hits = pipeline.retrieve(messages[index].content)
        if (hits.isEmpty()) return messages
        return messages.toMutableList().also { copy ->
            copy[index] = copy[index].copy(content = RagPrompt.augment(copy[index].content, hits, parser::displayName))
        }
    }
}
