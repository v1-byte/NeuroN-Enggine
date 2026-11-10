package com.neuron.engine

import android.content.Context
import com.neuron.model.AiProject
import com.neuron.model.EngineMode
import com.neuron.model.SecretStore
import com.neuron.model.validate
import com.neuron.engine.EngineHub
import com.neuron.engine.LlamaCppEngine
import com.neuron.project.ProjectRepository
import com.neuron.project.VirtualTree
import com.neuron.server.LocalServerService
import com.neuron.server.ServerPrefs
import com.neuron.hf.HfClient
import com.neuron.hf.HfDownloadWorker
import com.neuron.hf.HfPrefs
import com.neuron.copilot.CopilotAgent
import com.neuron.copilot.FileChange
import com.neuron.rag.FileParser
import com.neuron.rag.RagPipeline
import com.neuron.rag.SqliteVectorStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import androidx.work.WorkManager
import org.json.JSONArray
import org.json.JSONObject
import android.util.Base64
import java.security.SecureRandom

/**
 * Satu sumber kebenaran untuk UI: proyek "default" di filesDir/projects (lokasi yang sama dengan LocalServerService).
 * Kunci API TIDAK pernah ditulis ke project.json; ia hanya disimpan di SecretStore (terenkripsi).
 */
internal object ProjectStore {
    const val NAME = "default"
    const val API_KEY = "apiKey"
    private const val SECRETS = "neuron_secrets"

    fun repo(ctx: Context) = ProjectRepository(File(ctx.applicationContext.filesDir, "projects"))
    fun secrets(ctx: Context) = SecretStore(ctx.applicationContext, SECRETS)
    fun load(ctx: Context): AiProject = repo(ctx).loadOrCreate(NAME)

    fun save(ctx: Context, p: AiProject) {
        if (p.engine.apiKey.isNotBlank()) secrets(ctx).put(API_KEY, p.engine.apiKey)
        repo(ctx).save(p.copy(engine = p.engine.copy(apiKey = "")))
    }
}

/**
 * MethodChannel "neuron/project":
 *  - open            -> {name, paths}  daftar 17 berkas virtual (urutan Explorer)
 *  - read   {path}   -> teks berkas
 *  - write  {path,text} -> validasi lewat VirtualTree.write, lalu simpan. Gagal = error berisi pesan validasi.
 *  - loadEngine      -> {baseUrl, model, apiKey}
 *  - saveEngine {baseUrl, model, apiKey} -> mode API; apiKey kosong = hapus kunci
 *  - loadFeatures    -> {tools, words, regex}
 *  - setTools {enabled}  -> tools = BuiltinTools.defs bila aktif, kosong bila tidak
 *  - saveGuardrails {words, regex}
 *  - loadChatHistory / saveChatHistory {lines, conversation} / clearChatHistory
 *  - loadDrafts / saveDraft {path, text}; draft dibuang setelah project berhasil disimpan
 * Berkas dibaca dan ditulis di thread IO; hasilnya dikirim kembali di thread utama.
 */
internal object ProjectBridge {
    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        MethodChannel(messenger, "neuron/project").setMethodCallHandler { call, result ->
            val a = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
            when (call.method) {
                "open" -> reply(scope, result) { mapOf("name" to ProjectStore.NAME, "paths" to VirtualTree.paths) }
                "read" -> reply(scope, result) { VirtualTree.read(ProjectStore.load(app), str(a, "path")) }
                "write" -> reply(scope, result) { writeFile(app, str(a, "path"), str(a, "text")) }
                "loadEngine" -> reply(scope, result) { engineState(app) }
                "saveEngine" -> reply(scope, result) {
                    saveEngine(app, str(a, "baseUrl"), str(a, "model"), a["apiKey"] as? String)
                }
                "setEngineMode" -> reply(scope, result) { setEngineMode(app, str(a, "mode")) }
                "setLocalModel" -> reply(scope, result) { setLocalModel(app, str(a, "path")) }
                "serverState" -> reply(scope, result) { serverState(app) }
                "saveServer" -> reply(scope, result) { saveServer(app, (a["port"] as? Number)?.toInt() ?: 8080, str(a, "apiKey")) }
                "generateServerKey" -> reply(scope, result) { generateServerKey() }
                "startServer" -> reply(scope, result) { LocalServerService.start(app); mapOf("ok" to true) }
                "stopServer" -> reply(scope, result) { LocalServerService.stop(app); mapOf("ok" to true) }
                "addKnowledgeFile" -> reply(scope, result) { addKnowledgeFile(app, str(a, "path")) }
                "knowledgeState" -> reply(scope, result) { knowledgeState(app) }
                "indexKnowledge" -> reply(scope, result) { indexKnowledge(app) }
                "hfSaveToken" -> reply(scope, result) { HfPrefs(app).token = a["token"] as? String; mapOf("ok" to true) }
                "hfSearch" -> reply(scope, result) { hfSearch(app, str(a, "query")) }
                "hfFiles" -> reply(scope, result) { hfFiles(app, str(a, "repo")) }
                "hfDownload" -> reply(scope, result) { hfDownload(app, str(a, "repo"), str(a, "file")) }
                "hfStartDownload" -> reply(scope, result) { hfStartDownload(app, str(a, "repo"), str(a, "file")) }
                "hfDownloadState" -> reply(scope, result) { hfDownloadState(app, str(a, "id")) }
                "hfCancelDownload" -> reply(scope, result) { hfCancelDownload(app, str(a, "id")) }
                "copilotSuggest" -> reply(scope, result) { copilotSuggest(app, str(a, "complaint"), str(a, "sample"), str(a, "focus").ifBlank { null }) }
                "copilotApply" -> reply(scope, result) { copilotApply(app, str(a, "path"), str(a, "oldText"), str(a, "newText")) }
                "loadFeatures" -> reply(scope, result) { featureState(app) }
                "setTools" -> reply(scope, result) { setTools(app, a["enabled"] == true) }
                "saveGuardrails" -> reply(scope, result) { saveGuardrails(app, strList(a, "words"), strList(a, "regex")) }
                "loadChatHistory" -> reply(scope, result) { loadChatHistory(app) }
                "saveChatHistory" -> reply(scope, result) { saveChatHistory(app, a) }
                "clearChatHistory" -> reply(scope, result) { clearChatHistory(app) }
                "loadDrafts" -> reply(scope, result) { loadDrafts(app) }
                "saveDraft" -> reply(scope, result) { saveDraft(app, str(a, "path"), str(a, "text")) }
                else -> result.notImplemented()
            }
        }
    }

    private fun reply(scope: CoroutineScope, result: MethodChannel.Result, block: () -> Any?) {
        scope.launch {
            runCatching { withContext(Dispatchers.IO) { block() } }
                .onSuccess { result.success(it) }
                .onFailure { result.error("PROJECT_ERROR", it.message ?: it.javaClass.simpleName, null) }
        }
    }

    private fun writeFile(ctx: Context, path: String, text: String): Map<String, Any> {
        val updated = VirtualTree.write(ProjectStore.load(ctx), path, text).getOrThrow()
        ProjectStore.save(ctx, updated)
        runCatching { clearDraft(ctx, path) }
        return mapOf("ok" to true)
    }

    private fun engineState(ctx: Context): Map<String, Any> {
        val p = ProjectStore.load(ctx)
        val e = p.engine
        return mapOf(
            "baseUrl" to e.baseUrl,
            "model" to e.model,
            "mode" to e.mode.name,
            "modelPath" to p.files.modelPath,
            "nativeAvailable" to LlamaCppEngine.available,
            "apiKey" to (ProjectStore.secrets(ctx).get(ProjectStore.API_KEY) ?: ""),
        )
    }

    private fun saveEngine(ctx: Context, baseUrl: String, model: String, apiKey: String?): Map<String, Any> {
        val p = ProjectStore.load(ctx)
        ProjectStore.save(
            ctx,
            p.copy(engine = p.engine.copy(mode = EngineMode.API, baseUrl = baseUrl.trim(), model = model.trim(), apiKey = "")),
        )
        ProjectStore.secrets(ctx).put(ProjectStore.API_KEY, apiKey?.trim()?.takeIf { it.isNotEmpty() })
        return mapOf("ok" to true)
    }

    private fun featureState(ctx: Context): Map<String, Any> {
        val f = ProjectStore.load(ctx).features
        return mapOf("tools" to f.tools.isNotEmpty(), "words" to f.guardrailBlockedWords, "regex" to f.guardrailRegex)
    }

    private fun setTools(ctx: Context, enabled: Boolean): Map<String, Any> {
        val p = ProjectStore.load(ctx)
        ProjectStore.save(ctx, p.copy(features = p.features.copy(tools = if (enabled) BuiltinTools.defs else emptyList())))
        return mapOf("ok" to true)
    }

    private fun saveGuardrails(ctx: Context, words: List<String>, regex: List<String>): Map<String, Any> {
        regex.forEach { Regex(it) }   // pola tidak valid melempar PatternSyntaxException dengan pesan yang jelas
        val p = ProjectStore.load(ctx)
        val f = p.features.copy(guardrailBlockedWords = words, guardrailRegex = regex).also { it.validate() }
        ProjectStore.save(ctx, p.copy(features = f))
        return mapOf("ok" to true)
    }

    private fun setEngineMode(ctx: Context, mode: String): Map<String, Any> {
        require(mode == "API" || mode == "LOCAL") { "Mode engine tidak dikenal" }
        val p = ProjectStore.load(ctx)
        ProjectStore.save(ctx, p.copy(engine = p.engine.copy(mode = EngineMode.valueOf(mode))))
        return mapOf("nativeAvailable" to LlamaCppEngine.available)
    }

    private fun setLocalModel(ctx: Context, source: String): Map<String, Any> {
        val src = File(source)
        require(src.isFile && src.extension.equals("gguf", true)) { "Pilih berkas model .gguf yang valid" }
        val dir = ctx.getExternalFilesDir("models") ?: File(ctx.filesDir, "models")
        dir.mkdirs()
        val target = File(dir, src.name)
        if (src.canonicalFile != target.canonicalFile) src.inputStream().use { input -> target.outputStream().use { output -> input.copyTo(output) } }
        val p = ProjectStore.load(ctx)
        ProjectStore.save(ctx, p.copy(engine = p.engine.copy(mode = EngineMode.LOCAL), files = p.files.copy(modelPath = target.absolutePath)))
        return mapOf("path" to target.absolutePath, "nativeAvailable" to LlamaCppEngine.available)
    }

    private fun serverState(ctx: Context): Map<String, Any?> {
        val state = LocalServerService.state.value
        val prefs = ServerPrefs(ctx)
        return mapOf("running" to state.running, "address" to state.address, "error" to state.error, "port" to prefs.port, "apiKey" to prefs.apiKey)
    }

    private fun saveServer(ctx: Context, port: Int, key: String): Map<String, Any> {
        require(port in 1024..65535) { "Port harus 1024–65535" }
        require(key.trim().length >= ServerPrefs.MIN_KEY_LENGTH) { "API key minimal ${ServerPrefs.MIN_KEY_LENGTH} karakter" }
        ServerPrefs(ctx).apply { this.port = port; apiKey = key.trim() }
        return mapOf("ok" to true)
    }

    private fun generateServerKey(): String {
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    private fun addKnowledgeFile(ctx: Context, source: String): Map<String, Any> {
        val src = File(source)
        require(src.isFile) { "Berkas sumber tidak ditemukan" }
        require(src.length() <= 25L * 1024 * 1024) { "Berkas maksimal 25 MB" }
        val parser = FileParser(ctx)
        val safeName = src.name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val dest = File(parser.baseDir, "${UUID.randomUUID()}_$safeName")
        src.inputStream().use { input -> dest.outputStream().use { output -> input.copyTo(output) } }
        val p = ProjectStore.load(ctx)
        val files = (p.knowledge.knowledgeFiles + dest.absolutePath).distinct()
        ProjectStore.save(ctx, p.copy(knowledge = p.knowledge.copy(knowledgeFiles = files, ragEnabled = true)))
        return mapOf("name" to dest.name, "count" to files.size)
    }

    private fun knowledgeState(ctx: Context): Map<String, Any> {
        val p = ProjectStore.load(ctx)
        val store = SqliteVectorStore(ctx, File(ctx.filesDir, "rag/knowledge.db"))
        return mapOf("files" to p.knowledge.knowledgeFiles, "enabled" to p.knowledge.ragEnabled, "chunks" to store.count())
    }

    private fun indexKnowledge(ctx: Context): Map<String, Any> = runBlocking(Dispatchers.IO) {
        val original = ProjectStore.load(ctx)
        val key = ProjectStore.secrets(ctx).get(ProjectStore.API_KEY) ?: ""
        val p = original.copy(engine = original.engine.copy(apiKey = key))
        require(p.knowledge.knowledgeFiles.isNotEmpty()) { "Tambahkan dokumen sebelum membuat indeks" }
        val engine = EngineHub.ensure(p)
        val store = SqliteVectorStore(ctx, File(ctx.filesDir, "rag/knowledge.db"))
        val report = RagPipeline(engine, store, p.knowledge, FileParser(ctx), "${p.engine.mode}:${p.files.modelPath}:${p.engine.model}").sync()
        mapOf("indexed" to report.indexed, "skipped" to report.skipped, "chunks" to store.count(), "failed" to report.failed)
    }

    private fun hfSearch(ctx: Context, query: String): List<Map<String, Any?>> = runBlocking(Dispatchers.IO) {
        require(query.isNotBlank()) { "Masukkan kata pencarian" }
        HfClient(HfPrefs(ctx).token).search(query, filter = "gguf", limit = 15).map {
            mapOf("id" to it.id, "downloads" to it.downloads, "likes" to it.likes, "pipeline" to it.pipeline_tag)
        }
    }

    private fun hfFiles(ctx: Context, repo: String): List<Map<String, Any?>> = runBlocking(Dispatchers.IO) {
        HfClient(HfPrefs(ctx).token).detail(repo).siblings.filter { it.rfilename.endsWith(".gguf", true) }.map {
            mapOf("name" to it.rfilename, "size" to it.size)
        }
    }

    private fun hfDownload(ctx: Context, repo: String, file: String): Map<String, Any?> = runBlocking(Dispatchers.IO) {
        require(repo.matches(Regex("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"))) { "ID repo tidak valid" }
        require(file.endsWith(".gguf", true) && !file.contains("..")) { "Pilih berkas GGUF" }
        val base = ctx.getExternalFilesDir("models") ?: File(ctx.filesDir, "models")
        val result = HfClient(HfPrefs(ctx).token).downloadFiles(repo, listOf(file), base).first()
        check(result.ok) { result.error ?: "Unduhan gagal" }
        val path = File(HfClient.targetDir(base, repo), file).absolutePath
        val p = ProjectStore.load(ctx)
        ProjectStore.save(ctx, p.copy(engine = p.engine.copy(mode = EngineMode.LOCAL), files = p.files.copy(modelPath = path)))
        mapOf("path" to path, "bytes" to result.bytes, "verified" to result.verified)
    }

    /** Memulai unduhan WorkManager agar Flutter dapat menampilkan progres byte dan membatalkan. */
    private fun hfStartDownload(ctx: Context, repo: String, file: String): Map<String, Any> {
        require(repo.matches(Regex("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"))) { "ID repo tidak valid" }
        require(file.endsWith(".gguf", true) && !file.contains("..")) { "Pilih berkas GGUF" }
        val id = HfDownloadWorker.enqueue(ctx, repo, listOf(file))
        return mapOf("id" to id.toString(), "repo" to repo, "file" to file)
    }

    private fun hfDownloadState(ctx: Context, rawId: String): Map<String, Any?> {
        val id = runCatching { UUID.fromString(rawId) }.getOrElse { return mapOf("state" to "invalid") }
        val info = WorkManager.getInstance(ctx).getWorkInfoById(id).get()
            ?: return mapOf("state" to "missing")
        val p = info.progress
        val out = info.outputData
        return mapOf(
            "state" to info.state.name.lowercase(),
            "file" to (p.getString(HfDownloadWorker.KEY_FILE) ?: ""),
            "index" to p.getInt(HfDownloadWorker.KEY_IDX, 0),
            "count" to p.getInt(HfDownloadWorker.KEY_COUNT, 0),
            "done" to p.getLong(HfDownloadWorker.KEY_DONE, 0L),
            "total" to p.getLong(HfDownloadWorker.KEY_TOTAL, -1L),
            "path" to (out.getString(HfDownloadWorker.KEY_OUT) ?: ""),
            "error" to (out.getString(HfDownloadWorker.KEY_ERROR) ?: ""),
        )
    }

    private fun hfCancelDownload(ctx: Context, rawId: String): Map<String, Any> {
        WorkManager.getInstance(ctx).cancelWorkById(UUID.fromString(rawId))
        return mapOf("ok" to true)
    }

    private fun copilotSuggest(ctx: Context, complaint: String, sample: String, focus: String?): Map<String, Any?> = runBlocking(Dispatchers.IO) {
        require(complaint.isNotBlank()) { "Jelaskan masalah yang ingin diperbaiki" }
        val base = ProjectStore.load(ctx)
        val key = ProjectStore.secrets(ctx).get(ProjectStore.API_KEY) ?: ""
        val project = base.copy(engine = base.engine.copy(apiKey = key))
        val brain = CopilotAgent(EngineFactory.wrap(EngineHub.ensure(project), project))
        val s = brain.suggest(project, complaint, sample, focus)
        mapOf("reason" to s.reason, "changes" to s.changes.map { c -> mapOf("path" to c.path, "oldText" to c.oldText, "newText" to c.newText, "error" to c.error, "reason" to c.reason) })
    }

    private fun copilotApply(ctx: Context, path: String, oldText: String, newText: String): Map<String, Any> {
        require(path.isNotBlank() && newText.isNotBlank()) { "Patch Copilot kosong" }
        val project = ProjectStore.load(ctx)
        val updated = CopilotAgent.applyChange(project, FileChange(path, oldText, newText)).getOrThrow()
        ProjectStore.save(ctx, updated)
        return mapOf("ok" to true, "path" to path)
    }

    /** Riwayat lokal di SharedPreferences privat aplikasi, terpisah dari project.json dan API key. */
    private fun loadChatHistory(ctx: Context): Map<String, Any> {
        val prefs = ctx.getSharedPreferences("neuron_chat_history", Context.MODE_PRIVATE)
        fun readArray(key: String): List<Map<String, String>> {
            val array = runCatching { JSONArray(prefs.getString(key, "[]")) }.getOrElse { JSONArray() }
            return (0 until array.length()).mapNotNull { i ->
                val item = array.optJSONObject(i) ?: return@mapNotNull null
                val role = item.optString("role")
                val text = item.optString(if (key == "lines") "text" else "content")
                if (role.isBlank()) null else mapOf("role" to role, (if (key == "lines") "text" else "content") to text)
            }
        }
        return mapOf("lines" to readArray("lines"), "conversation" to readArray("conversation"))
    }

    private fun saveChatHistory(ctx: Context, args: Map<*, *>): Map<String, Any> {
        fun encode(key: String, bodyKey: String, maxItems: Int, allowed: Set<String>): String {
            val items = (args[key] as? List<*>)?.mapNotNull { it as? Map<*, *> }.orEmpty()
                .filter { (it["role"] as? String) in allowed }
                .takeLast(maxItems)
            val array = JSONArray()
            items.forEach { item ->
                val row = JSONObject()
                row.put("role", item["role"] as String)
                row.put(bodyKey, (item[bodyKey] as? String ?: "").takeLast(1_500))
                array.put(row)
            }
            return array.toString()
        }
        val lines = encode("lines", "text", 160, setOf("user", "assistant", "error"))
        val conversation = encode("conversation", "content", 80, setOf("user", "assistant"))
        val saved = ctx.getSharedPreferences("neuron_chat_history", Context.MODE_PRIVATE).edit()
            .putString("lines", lines).putString("conversation", conversation).commit()
        check(saved) { "Riwayat chat gagal disimpan" }
        return mapOf("ok" to true)
    }

    private fun clearChatHistory(ctx: Context): Map<String, Any> {
        val cleared = ctx.getSharedPreferences("neuron_chat_history", Context.MODE_PRIVATE).edit()
            .remove("lines").remove("conversation").commit()
        check(cleared) { "Riwayat chat gagal dihapus" }
        return mapOf("ok" to true)
    }

    private fun loadDrafts(ctx: Context): Map<String, String> {
        val raw = ctx.getSharedPreferences("neuron_editor_drafts", Context.MODE_PRIVATE).getString("drafts", "{}")
        val json = runCatching { JSONObject(raw ?: "{}") }.getOrElse { JSONObject() }
        return VirtualTree.paths.filter { it != "engine/api.json" }.mapNotNull { path ->
            if (json.has(path)) path to json.optString(path) else null
        }.toMap()
    }

    private fun saveDraft(ctx: Context, path: String, text: String): Map<String, Any> {
        require(path in VirtualTree.paths) { "Path draft tidak dikenal" }
        require(path != "engine/api.json") { "Draft berkas API tidak disimpan demi melindungi kunci" }
        require(text.length <= 256 * 1024) { "Draft terlalu besar untuk penyimpanan lokal" }
        val prefs = ctx.getSharedPreferences("neuron_editor_drafts", Context.MODE_PRIVATE)
        val json = runCatching { JSONObject(prefs.getString("drafts", "{}")) }.getOrElse { JSONObject() }
        json.put(path, text)
        check(prefs.edit().putString("drafts", json.toString()).commit()) { "Draft gagal disimpan" }
        return mapOf("ok" to true)
    }

    private fun clearDraft(ctx: Context, path: String) {
        val prefs = ctx.getSharedPreferences("neuron_editor_drafts", Context.MODE_PRIVATE)
        val json = runCatching { JSONObject(prefs.getString("drafts", "{}")) }.getOrElse { JSONObject() }
        json.remove(path)
        prefs.edit().putString("drafts", json.toString()).commit()
    }

    private fun str(a: Map<*, *>, key: String): String = a[key] as? String ?: ""

    private fun strList(a: Map<*, *>, key: String): List<String> =
        (a[key] as? List<*>)?.map { it.toString().trim() }?.filter { it.isNotEmpty() } ?: emptyList()
}
