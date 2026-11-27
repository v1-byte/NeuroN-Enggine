package com.neuron.engine

import android.content.Context
import com.neuron.model.ChatParams
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
import com.neuron.model.AiProject

/**
 * Jembatan Flutter <-> engine Kotlin (jalur A di docs/MIGRASI_FLUTTER.md bagian 5).
 *  - "neuron/project" (ProjectBridge.kt): berkas proyek, fitur.
 *  - "neuron/chat" (EventChannel): stream hasil generate dari model GGUF lokal (llama.cpp). Argumen hanya riwayat pesan;
 *    engine dan parameter dibaca dari proyek yang tersimpan. Setiap event adalah:
 *      String                          -> potongan token jawaban
 *      Map {type:"notice", text:"..."} -> peringatan non-fatal untuk ditampilkan (RAG dimatikan, template ChatML, riwayat dipangkas)
 *    Kegagalan dikirim sebagai error dengan kode ENGINE_NATIVE / ENGINE_MODEL / ENGINE_RAM / ENGINE_CONTEXT /
 *    ENGINE_CANCELLED (atau CHAT_ERROR bila tidak terklasifikasi). Membatalkan langganan = menghentikan generate native.
 *    Tidak ada mode API: konfigurasi API lama diabaikan (lihat ChatFlags.legacyApiNoticePending).
 */
object NeuronBridge {
    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        ProjectBridge.register(messenger, app)
        // Semua jalur pemuatan model (chat, runModel, RAG, Copilot) melewati pemeriksaan native/model/RAM lebih dulu.
        EngineHub.preflight = { project -> EnginePreflight.check(app, project) }
        // Parameter generate per model (tab "Parameter" di Edit model): menimpa nilai proyek untuk model yang bersangkutan.
        ModelDefaults.perModel = { modelPath -> ModelParamStore.get(app, File(modelPath).name) }
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
                EngineWarnings.drain()   // buang peringatan sisa dari permintaan lain
                val (engine, params, project) = withContext(Dispatchers.IO) { prepare() }
                ragNotice(project)?.let { events.success(notice(it)) }
                val contextual = withContext(Dispatchers.IO) { addKnowledgeContext(messages, project, engine) }
                engine.chat(contextual, params).collect { token ->
                    flushWarnings(events)
                    events.success(token)
                }
                flushWarnings(events)
                events.endOfStream()
            } catch (e: CancellationException) {
                throw e   // dibatalkan dari Dart (tombol Stop): tidak perlu melapor
            } catch (e: Throwable) {
                flushWarnings(events)
                val failure = EngineErrors.classify(e)
                events.error(failure.kind.code, failure.message ?: failure.kind.name, null)
                events.endOfStream()
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        job?.cancel()
        job = null
    }

    private fun notice(text: String): Map<String, String> = mapOf("type" to "notice", "text" to text)

    private fun flushWarnings(events: EventChannel.EventSink) {
        for (w in EngineWarnings.drain()) events.success(notice(w))
    }

    /** Engine (dengan fitur tools/guardrail dari proyek) dan parameter chat dari chat/params.json yang tersimpan. */
    private suspend fun prepare(): Triple<InferenceEngine, ChatParams, AiProject> {
        val p = ProjectStore.load(ctx)
        if (p.files.modelPath.isBlank()) throw EngineException(EngineErrorKind.MODEL, "Belum ada model lokal aktif. Unduh atau impor model GGUF dulu.")
        val raw = EngineHub.ensure(p)
        val params = ChatResponsePrompt.apply(ModelDefaults.effective(p), p.features.responseMode)
        return Triple(EngineFactory.wrap(raw, p), params, p)
    }

    /**
     * RAG di chat dimatikan secara bawaan (pengujian awal): tanpa ini setiap pesan memanggil embedding dengan model chat
     * yang sama sebelum generate, sehingga sulit memisahkan masalah engine dari masalah RAG. Aktifkan lewat Pengaturan
     * setelah chat polos berjalan baik. Indeks dan dokumen tidak dihapus.
     */
    private fun ragNotice(project: AiProject): String? =
        if (project.knowledge.ragEnabled && project.knowledge.knowledgeFiles.isNotEmpty() && !ChatFlags.ragInChat(ctx))
            "RAG dimatikan di chat selama pengujian awal; dokumen pengetahuan tidak dipakai untuk jawaban ini. Aktifkan di Pengaturan → RAG di chat."
        else null

    private suspend fun addKnowledgeContext(
        messages: List<ChatMessage>,
        project: AiProject,
        engine: InferenceEngine,
    ): List<ChatMessage> {
        if (!project.knowledge.ragEnabled || messages.isEmpty()) return messages
        if (!ChatFlags.ragInChat(ctx)) return messages
        val index = messages.indexOfLast { it.role == "user" }
        if (index < 0) return messages
        val store = SqliteVectorStore(ctx, File(ctx.filesDir, "rag/knowledge.db"))
        if (store.count() == 0) return messages
        val parser = FileParser(ctx)
        val pipeline = RagPipeline(engine, store, project.knowledge, parser,
            "${project.engine.mode}:${project.files.modelPath}")
        val hits = pipeline.retrieve(messages[index].content)
        if (hits.isEmpty()) return messages
        return messages.toMutableList().also { copy ->
            copy[index] = copy[index].copy(content = RagPrompt.augment(copy[index].content, hits, parser::displayName))
        }
    }
}

/** Saklar runtime yang sengaja tidak masuk project.json (bukan bagian konfigurasi model). Bawaan: RAG di chat mati. */
internal object ChatFlags {
    private const val PREFS = "neuron_flags"
    private const val RAG_IN_CHAT = "rag_in_chat"
    private const val LEGACY_API_NOTICE = "legacy_api_notice"

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun ragInChat(ctx: Context): Boolean = prefs(ctx).getBoolean(RAG_IN_CHAT, false)
    fun setRagInChat(ctx: Context, enabled: Boolean) { prefs(ctx).edit().putBoolean(RAG_IN_CHAT, enabled).commit() }

    fun legacyApiNoticePending(ctx: Context): Boolean = prefs(ctx).getBoolean(LEGACY_API_NOTICE, false)
    fun setLegacyApiNoticePending(ctx: Context, pending: Boolean) { prefs(ctx).edit().putBoolean(LEGACY_API_NOTICE, pending).commit() }
}
