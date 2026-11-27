package com.neuron.engine

import android.content.Context
import com.neuron.model.AiProject
import com.neuron.model.SecretStore
import com.neuron.model.validate
import com.neuron.model.DeviceHealth
import com.neuron.model.PrivacyPolicy
import com.neuron.engine.EngineHub
import com.neuron.engine.LlamaCppEngine
import com.neuron.engine.GgufCancelled
import com.neuron.engine.GgufEdit
import com.neuron.engine.GgufEditor
import com.neuron.engine.GgmlTypes
import com.neuron.engine.GgufEntry
import com.neuron.engine.GgufException
import com.neuron.engine.GgufFile
import com.neuron.engine.GgufReader
import com.neuron.engine.GgufReport
import com.neuron.engine.GgufType
import com.neuron.project.ProjectRepository
import com.neuron.project.VirtualTree
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
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import android.util.Base64
import java.security.SecureRandom

/**
 * Satu sumber kebenaran untuk UI: proyek "default" di filesDir/projects.
 * Hanya mesin lokal. Rahasia (token HF, kunci trainer) disimpan di SecretStore (terenkripsi), bukan di project.json.
 */
internal object ProjectStore {
    const val NAME = "default"
    const val API_KEY = "apiKey"
    const val TRAINER_API_KEY = "remoteTrainerApiKey"
    private const val SECRETS = "neuron_secrets"

    fun repo(ctx: Context) = ProjectRepository(File(ctx.applicationContext.filesDir, "projects"))
    fun secrets(ctx: Context) = SecretStore(ctx.applicationContext, SECRETS)
    @Volatile private var legacyKeyWiped = false
    @Volatile private var legacyChecked = false

    /**
     * Konfigurasi API lama (engine.mode "API", baseUrl, apiKey, model di project.json, atau kunci API di SecretStore)
     * TIDAK pernah dipakai: kode saat ini hanya mendukung mode lokal. Bila ditemukan, berkas ditulis ulang tanpa bidang
     * itu dan pengguna diberi tahu sekali lewat ChatFlags.legacyApiNoticePending (dibaca engineState, dihapus ackLegacyApi).
     */
    private fun detectLegacyApi(ctx: Context) {
        if (legacyChecked) return
        legacyChecked = true
        runCatching {
            val r = repo(ctx)
            if (r.hasLegacyApiConfig(NAME)) {
                ChatFlags.setLegacyApiNoticePending(ctx, true)
                r.save(r.loadOrCreate(NAME))   // simpan ulang: bidang API lama hilang dari project.json
            }
        }
    }

    fun load(ctx: Context): AiProject {
        detectLegacyApi(ctx)
        val project = repo(ctx).loadOrCreate(NAME)
        if (!legacyKeyWiped) {   // mode API sudah dihapus: buang kunci API lama dari penyimpanan terenkripsi
            legacyKeyWiped = true
            runCatching {
                secrets(ctx).let {
                    if (!it.get(API_KEY).isNullOrBlank()) {
                        it.put(API_KEY, null)
                        ChatFlags.setLegacyApiNoticePending(ctx, true)
                    }
                }
            }
        }
        if (project.training.remoteTrainerApiKey.isNotBlank()) {
            val secretStore = secrets(ctx)
            if (secretStore.get(TRAINER_API_KEY).isNullOrBlank()) {
                secretStore.put(TRAINER_API_KEY, project.training.remoteTrainerApiKey)
            }
            val safe = project.copy(training = project.training.copy(remoteTrainerApiKey = ""))
            repo(ctx).save(safe)
            return safe
        }
        return project
    }

    fun save(ctx: Context, p: AiProject) {
        if (p.training.remoteTrainerApiKey.isNotBlank()) secrets(ctx).put(TRAINER_API_KEY, p.training.remoteTrainerApiKey)
        repo(ctx).save(p.copy(training = p.training.copy(remoteTrainerApiKey = "")))
    }
}

/**
 * MethodChannel "neuron/project":
 *  - open            -> {name, paths}  daftar 17 berkas virtual (urutan Explorer)
 *  - read   {path}   -> teks berkas
 *  - write  {path,text} -> validasi lewat VirtualTree.write, lalu simpan. Gagal = error berisi pesan validasi. Hasil: {ok, warning?}
 *  - loadEngine      -> {model, mode: "LOCAL", modelPath, nativeAvailable, legacyApi}; legacyApi = konfigurasi API lama ditemukan dan diabaikan
 *  - chatFlags / setRagInChat {enabled} / ackLegacyApi -> saklar runtime (RAG di chat mati secara bawaan) dan konfirmasi notice
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
                "chatFlags" -> reply(scope, result) { mapOf("ragInChat" to ChatFlags.ragInChat(app)) }
                "setRagInChat" -> reply(scope, result) { ChatFlags.setRagInChat(app, a["enabled"] == true); mapOf("ok" to true, "ragInChat" to ChatFlags.ragInChat(app)) }
                "ackLegacyApi" -> reply(scope, result) { ChatFlags.setLegacyApiNoticePending(app, false); mapOf("ok" to true) }
                "setLocalModel" -> reply(scope, result) { setLocalModel(app, str(a, "path")) }
                "localModels" -> reply(scope, result) { localModels(app, a["hash"] != false) }
                "activateLocalModel" -> reply(scope, result) { activateLocalModel(app, str(a, "path")) }
                "deleteLocalModel" -> reply(scope, result) { deleteLocalModel(app, str(a, "path")) }
                "renameLocalModel" -> reply(scope, result) { renameLocalModel(app, str(a, "path"), str(a, "name")) }
                "ggufInspect" -> reply(scope, result) { ggufInspect(app, str(a, "path")) }
                "ggufTensors" -> reply(scope, result) { ggufTensors(app, str(a, "path"), str(a, "query"), (a["offset"] as? Number)?.toInt() ?: 0, (a["limit"] as? Number)?.toInt() ?: 100) }
                "ggufArray" -> reply(scope, result) { ggufArray(app, str(a, "path"), str(a, "key"), (a["offset"] as? Number)?.toLong() ?: 0L, (a["limit"] as? Number)?.toInt() ?: 100) }
                "importLocalModel" -> reply(scope, result) { importLocalModel(app, str(a, "path")) }
                "localModelProfile" -> reply(scope, result) { localModelProfile(app, str(a, "path")) }
                "ggufSave" -> reply(scope, result) { ggufSave(app, str(a, "path"), a["edits"] as? List<*> ?: emptyList<Any>(), a["activate"] == true) }
                "ggufProgress" -> reply(scope, result) { GgufJob.snapshot() }
                "modelParamsGet" -> reply(scope, result) { ModelParamsBridge.state(app, modelFile(app, str(a, "path"))) }
                "modelParamsSave" -> reply(scope, result) { ModelParamsBridge.save(app, modelFile(app, str(a, "path")), str(a, "params")) }
                "modelParamsClear" -> reply(scope, result) { ModelParamsBridge.clear(app, modelFile(app, str(a, "path"))) }
                "modelParamsTest" -> reply(scope, result) {
                    ModelParamsBridge.test(app, modelFile(app, str(a, "path")), str(a, "prompt"), str(a, "params"), (a["maxTokens"] as? Number)?.toInt() ?: 128)
                }
                "ggufCancel" -> reply(scope, result) { GgufJob.cancel = true; mapOf("ok" to true) }
                "verifyLocalModel" -> reply(scope, result) { verifyLocalModel(app, str(a, "path")) }
                "exportLocalModelMetadata" -> reply(scope, result) { exportLocalModelMetadata(app, str(a, "path")) }
                "deviceHealth" -> reply(scope, result) { deviceHealth(app, (a["modelSize"] as? Number)?.toLong() ?: 0L) }
                "addKnowledgeFile" -> reply(scope, result) { addKnowledgeFile(app, str(a, "path")) }
                "knowledgeState" -> reply(scope, result) { knowledgeState(app) }
                "indexKnowledge" -> reply(scope, result) { indexKnowledge(app) }
                "hfSaveToken" -> reply(scope, result) { HfPrefs(app).token = a["token"] as? String; mapOf("ok" to true) }
                "hfSearch" -> reply(scope, result) { hfSearch(app, str(a, "query"), a["scope"]?.toString() ?: "all") }
                "hfFiles" -> reply(scope, result) { hfFiles(app, str(a, "repo")) }
                "hfRevision" -> reply(scope, result) { hfRevision(app, str(a, "repo")) }
                "trackLocalModelSource" -> reply(scope, result) { trackLocalModelSource(app, str(a, "path"), str(a, "repo"), str(a, "revision")) }
                "checkLocalModelUpdate" -> reply(scope, result) { checkLocalModelUpdate(app, str(a, "path")) }
                "hfDownload" -> reply(scope, result) { hfDownload(app, str(a, "repo"), str(a, "file")) }
                "hfStartDownload" -> reply(scope, result) { hfStartDownload(app, str(a, "repo"), str(a, "file"), str(a, "revision")) }
                "hfStartModelDownload" -> reply(scope, result) { hfStartModelDownload(app, str(a, "repo"), a["files"] as? List<*> ?: emptyList<Any>(), str(a, "revision")) }
                "hfDownloadState" -> reply(scope, result) { hfDownloadState(app, str(a, "id")) }
                "hfDownloadHistory" -> reply(scope, result) { HfDownloadWorker.history(app) }
                "hfPauseDownload" -> reply(scope, result) { hfPauseDownload(app, str(a, "id")) }
                "hfResumeDownload" -> reply(scope, result) { hfResumeDownload(app, str(a, "id")) }
                "hfCancelDownload" -> reply(scope, result) { hfCancelDownload(app, str(a, "id")) }
                "trainingLoadConfig" -> reply(scope, result) { TrainingBridge.loadConfig(app) }
                "trainingSaveConfig" -> reply(scope, result) { TrainingBridge.saveConfig(app, str(a, "config")) }
                "runModelOperation" -> reply(scope, result) { TrainingBridge.runModelOperation(app, str(a, "config")) }
                "runModelPipeline" -> reply(scope, result) { TrainingBridge.runModelPipeline(app, str(a, "config")) }
                "trainingInspectDataset" -> reply(scope, result) { TrainingBridge.inspectDataset(app, str(a, "path"), str(a, "method")) }
                "trainingStart" -> reply(scope, result) { TrainingBridge.start(app) }
                "trainingReconnect" -> reply(scope, result) { TrainingBridge.reconnect(app, str(a, "id")) }
                "trainingState" -> reply(scope, result) { TrainingBridge.state(app) }
                "trainingCancel" -> reply(scope, result) { TrainingBridge.cancel(app, str(a, "id")) }
                "trainingDownloadAdapter" -> reply(scope, result) { TrainingBridge.downloadAdapter(app, str(a, "id"), a["gguf"] == true) }
                "loraState" -> reply(scope, result) { LoraBridge.state(app) }
                "loraList" -> reply(scope, result) { LoraBridge.list(app) }
                "loraImport" -> reply(scope, result) { LoraBridge.importAdapter(app, str(a, "path")) }
                "loraAttach" -> reply(scope, result) { LoraBridge.attach(app, str(a, "path"), (a["scale"] as? Number)?.toFloat() ?: 1f) }
                "loraDetach" -> reply(scope, result) { LoraBridge.detach(app) }
                "loraSetScale" -> reply(scope, result) { LoraBridge.setScale(app, (a["scale"] as? Number)?.toFloat() ?: 1f) }
                "loraDelete" -> reply(scope, result) { LoraBridge.delete(app, str(a, "path")) }
                "loraAbTest" -> reply(scope, result) { LoraBridge.abTest(app, str(a, "prompt"), (a["maxTokens"] as? Number)?.toInt() ?: 128) }
                "runModel" -> reply(scope, result) { runModel(app) }
                "unloadModel" -> reply(scope, result) { unloadModel() }
                "modelState" -> reply(scope, result) { mapOf("loaded" to EngineHub.isLoaded, "nativeAvailable" to LlamaCppEngine.available) }
                "copilotSuggest" -> reply(scope, result) { copilotSuggest(app, str(a, "complaint"), str(a, "sample"), str(a, "focus").ifBlank { null }) }
                "copilotApply" -> reply(scope, result) { copilotApply(app, str(a, "path"), str(a, "oldText"), str(a, "newText")) }
                "loadFeatures" -> reply(scope, result) { featureState(app) }
                "setTools" -> reply(scope, result) { setTools(app, a["enabled"] == true) }
                "saveGuardrails" -> reply(scope, result) { saveGuardrails(app, strList(a, "words"), strList(a, "regex")) }
                "privacyModels" -> reply(scope, result) { privacyModels(app) }
                "privacyLoad" -> reply(scope, result) { privacyLoad(app, str(a, "path")) }
                "privacyFetch" -> reply(scope, result) { privacyFetch(app, str(a, "path")) }
                "privacyApply" -> reply(scope, result) { privacyApply(app, str(a, "path"), str(a, "text"), a["use"] == true) }
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
                .onFailure {
                    // Kegagalan engine membawa kode jenisnya (ENGINE_NATIVE/MODEL/RAM/CONTEXT/CANCELLED); lainnya tetap PROJECT_ERROR.
                    val failure = EngineErrors.classify(it)
                    val code = if (failure.kind == EngineErrorKind.UNKNOWN) "PROJECT_ERROR" else failure.kind.code
                    result.error(code, failure.message ?: it.javaClass.simpleName, null)
                }
        }
    }

    private fun writeFile(ctx: Context, path: String, text: String): Map<String, Any> {
        val updated = VirtualTree.write(ProjectStore.load(ctx), path, text).getOrThrow()
        ProjectStore.save(ctx, updated)
        runCatching { clearDraft(ctx, path) }
        val warning = legacyApiWarning(path, text)
        return if (warning != null) mapOf("ok" to true, "warning" to warning) else mapOf("ok" to true)
    }

    /** engine/api.json yang berisi mode API/baseUrl/apiKey/model tetap diterima, tetapi bidang itu diabaikan: katakan terus terang. */
    private fun legacyApiWarning(path: String, text: String): String? {
        if (path != "engine/api.json") return null
        val engine = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
        if (!ProjectRepository.isLegacyApiEngine(engine)) return null
        return "Konfigurasi API diabaikan: NeuroN hanya menjalankan model GGUF lokal (llama.cpp). Berkas disimpan sebagai mode LOCAL tanpa Base URL, API key, atau nama model online."
    }

    private fun engineState(ctx: Context): Map<String, Any> {
        val p = ProjectStore.load(ctx)
        return mapOf(
            "model" to File(p.files.modelPath).name,
            "mode" to "LOCAL",
            "modelPath" to p.files.modelPath,
            "nativeAvailable" to LlamaCppEngine.available,
            "legacyApi" to ChatFlags.legacyApiNoticePending(ctx),
        )
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

    // ---- Privasi per model: setiap model lokal punya berkas privasinya sendiri (<model>.gguf.privacy.json, di samping model) ----

    private fun privacySidecar(model: File) = File(model.parentFile, model.name + ".privacy.json")

    /** Repo asal privacy.json: repo yang tertaut ke model; bila belum ditautkan, bytecode66/Froged_N1. */
    private fun privacySource(model: File): String =
        runCatching { JSONObject(modelSourceFile(model).readText()).optString("repo") }.getOrDefault("")
            .ifBlank { PrivacyPolicy.REPO }

    /** Model lokal yang bisa dipilih untuk diedit privasinya: terunduh, terimpor, atau aktif. */
    private fun privacyModels(ctx: Context): List<Map<String, Any>> {
        val active = ProjectStore.load(ctx).files.modelPath
        val lorasRoot = LoraBridge.dir(ctx).canonicalPath + File.separator
        return modelDir(ctx).walkTopDown()
            .filter { it.isFile && it.extension.equals("gguf", true) && !it.canonicalPath.startsWith(lorasRoot) }
            .sortedBy { it.name.lowercase() }
            .map { f ->
                mapOf(
                    "name" to f.name,
                    "path" to f.absolutePath,
                    "size" to f.length(),
                    "active" to (f.absolutePath == active),
                    "source" to privacySource(f),
                    "hasPrivacy" to privacySidecar(f).isFile,
                    "file" to privacySidecar(f).name,
                )
            }.toList()
    }

    /** Salinan privasi milik model ini (teks kosong bila belum pernah disimpan). */
    private fun privacyLoad(ctx: Context, path: String): Map<String, Any> {
        val model = modelFile(ctx, path)
        val f = privacySidecar(model)
        return mapOf(
            "text" to (if (f.isFile) f.readText() else ""),
            "exists" to f.isFile,
            "file" to f.name,
            "source" to privacySource(model),
        )
    }

    /** Unduh privacy.json dari repo asal model (hanya file itu). Belum disimpan: pengguna meninjau dan mengedit dulu. */
    private fun privacyFetch(ctx: Context, path: String): Map<String, Any> = runBlocking(Dispatchers.IO) {
        val model = modelFile(ctx, path)
        val repo = privacySource(model)
        val base = File(ctx.cacheDir, "privacy_fetch")
        base.deleteRecursively()
        try {
            val res = HfClient(HfPrefs(ctx).token).downloadFiles(repo, listOf(PrivacyPolicy.FILE), base).first()
            check(res.ok) { "${PrivacyPolicy.FILE} tidak bisa diambil dari $repo: ${res.error ?: "gagal"}" }
            val f = File(HfClient.targetDir(base, repo), PrivacyPolicy.FILE)
            check(f.length() <= PrivacyPolicy.MAX_BYTES) { "privacy.json terlalu besar" }
            val text = f.readText()
            PrivacyPolicy.parse(text)   // pastikan JSON valid sebelum masuk editor
            mapOf("text" to text, "source" to repo)
        } finally {
            base.deleteRecursively()
        }
    }

    /**
     * Simpan teks privasi ke berkas MODEL YANG DIPILIH. Bila [use] true, kata dan regex-nya juga digabung
     * (tanpa duplikat) ke guardrail; itu hanya boleh untuk model yang sedang aktif, karena guardrail berlaku
     * untuk chat dengan model aktif. Teks tidak valid ditolak dan tidak ada yang berubah.
     */
    private fun privacyApply(ctx: Context, path: String, text: String, use: Boolean): Map<String, Any> {
        val model = modelFile(ctx, path)
        val r = PrivacyPolicy.parse(text)
        if (use) {
            val active = ProjectStore.load(ctx).files.modelPath
            require(model.absolutePath == active) { "Model ini belum aktif. Aktifkan di Library dulu, atau pilih Simpan saja." }
        }
        val f = privacySidecar(model)
        val tmp = File(f.parentFile, f.name + ".tmp")
        tmp.writeText(text)
        tmp.copyTo(f, overwrite = true)
        tmp.delete()
        if (!use) return mapOf("used" to false, "file" to f.name, "words" to emptyList<String>(), "regex" to emptyList<String>(), "warnings" to r.warnings)
        val cur = ProjectStore.load(ctx).features
        val words = PrivacyPolicy.merge(cur.guardrailBlockedWords, r.words)
        val regex = PrivacyPolicy.merge(cur.guardrailRegex, r.regex)
        saveGuardrails(ctx, words, regex)
        return mapOf("used" to true, "file" to f.name, "words" to words, "regex" to regex, "warnings" to r.warnings)
    }

    private fun setLocalModel(ctx: Context, source: String): Map<String, Any> {
        val src = File(source)
        require(src.isFile && src.extension.equals("gguf", true)) { "Pilih berkas model .gguf yang valid" }
        require(!LoraAdapter.isAdapter(src)) { "${src.name} adalah adapter LoRA, bukan model dasar. Impor lewat Lainnya → LoRA." }
        val dir = ctx.getExternalFilesDir("models") ?: File(ctx.filesDir, "models")
        dir.mkdirs()
        val target = File(dir, src.name)
        if (src.canonicalFile != target.canonicalFile) src.inputStream().use { input -> target.outputStream().use { output -> input.copyTo(output) } }
        val p = ProjectStore.load(ctx)
        ProjectStore.save(ctx, p.copy(files = p.files.copy(modelPath = target.absolutePath)))
        return mapOf("path" to target.absolutePath, "nativeAvailable" to LlamaCppEngine.available)
    }

    /**
     * Salin model GGUF pilihan pengguna ke folder model TANPA mengaktifkannya (dipakai Editor GGUF).
     * Berkas bernama sama dengan ukuran sama dipakai ulang; ukuran beda ditolak agar model lama tidak tertimpa.
     */
    private fun importLocalModel(ctx: Context, source: String): Map<String, Any> {
        val src = File(source)
        require(src.isFile && src.extension.equals("gguf", true)) { "Pilih berkas model .gguf yang valid" }
        require(!LoraAdapter.isAdapter(src)) { "${src.name} adalah adapter LoRA, bukan model dasar. Impor lewat Lainnya → LoRA." }
        val target = File(modelDir(ctx), src.name)
        if (src.canonicalFile != target.canonicalFile) {
            if (target.exists()) {
                require(target.length() == src.length()) {
                    "Sudah ada model bernama ${src.name} dengan ukuran berbeda. Ganti nama file sumber atau hapus model lama dulu."
                }
            } else {
                val part = File(target.parentFile, src.name + ".part")
                try {
                    src.inputStream().use { input -> part.outputStream().use { output -> input.copyTo(output) } }
                    check(part.renameTo(target)) { "Model gagal disalin" }
                } finally {
                    part.delete()
                }
            }
        }
        return mapOf("path" to target.absolutePath, "name" to target.name)
    }

    /**
     * Ringkasan metadata GGUF untuk mengisi berkas Workspace (config.json, chat_template.jinja, quantization.json,
     * contextLength). Hanya angka/teks yang benar-benar ada di header; key yang tidak ada bernilai null.
     */
    private fun localModelProfile(ctx: Context, path: String): Map<String, Any?> {
        val file = modelFile(ctx, path)
        val g = GgufReader.read(file)
        val arch = g.string("general.architecture")
        fun num(suffix: String): Long? = if (arch == null) null else g.entry("$arch.$suffix")?.value as? Long
        return mapOf(
            "path" to file.absolutePath,
            "name" to file.name,
            "architecture" to arch,
            "modelName" to g.string("general.name"),
            "fileType" to (g.entry("general.file_type")?.value as? Long),
            "contextLength" to num("context_length"),
            "embeddingLength" to num("embedding_length"),
            "blockCount" to num("block_count"),
            "feedForwardLength" to num("feed_forward_length"),
            "headCount" to num("attention.head_count"),
            "headCountKv" to num("attention.head_count_kv"),
            "vocabSize" to g.tokenCount.takeIf { it >= 0L },
            "chatTemplate" to g.string("tokenizer.chat_template"),
        )
    }

    private fun modelDir(ctx: Context): File =
        (ctx.getExternalFilesDir("models") ?: File(ctx.filesDir, "models")).apply { mkdirs() }

    /**
     * SHA-256 model, di-cache per (path, ukuran, waktu ubah). Menghitung hash model ratusan MB tiap kali daftar dibuka
     * membuat Editor GGUF terasa macet; hash dihitung sekali lalu dipakai ulang. [compute] = false hanya membaca cache.
     */
    private fun modelSha(ctx: Context, f: File, compute: Boolean): String {
        val prefs = ctx.getSharedPreferences("neuron_model_sha", Context.MODE_PRIVATE)
        val key = "${f.absolutePath}|${f.length()}|${f.lastModified()}"
        prefs.getString(key, null)?.let { return it }
        if (!compute) return ""
        val sha = runCatching { HfClient().sha256(f) }.getOrDefault("")
        if (sha.isNotEmpty()) {
            val edit = prefs.edit()
            prefs.all.keys.filter { it.startsWith(f.absolutePath + "|") }.forEach { edit.remove(it) }
            edit.putString(key, sha).apply()
        }
        return sha
    }

    private fun localModels(ctx: Context, withHash: Boolean = true): List<Map<String, Any>> {
        LoraBridge.migrateStray(ctx)
        val dir = modelDir(ctx)
        val lorasRoot = LoraBridge.dir(ctx).canonicalPath + File.separator
        val active = ProjectStore.load(ctx).files.modelPath
        return dir.walkTopDown().filter { it.isFile && it.extension.equals("gguf", true) && !it.canonicalPath.startsWith(lorasRoot) }
            .sortedBy { it.name.lowercase() }
            .map { file ->
                val source = runCatching { JSONObject(modelSourceFile(file).readText()) }.getOrNull()
                mapOf(
                    "name" to file.name,
                    "path" to file.absolutePath,
                    "size" to file.length(),
                    "sha256" to modelSha(ctx, file, withHash),
                    "modified" to file.lastModified(),
                    "ramRecommended" to (file.length() * 1.25).toLong(),
                    "active" to (file.absolutePath == active),
                    "sourceRepo" to (source?.optString("repo") ?: ""),
                    "sourceRevision" to (source?.optString("revision") ?: ""),
                )
            }.toList()
    }

    private fun deleteLocalModel(ctx: Context, path: String): Map<String, Any> {
        val file = File(path).canonicalFile
        val root = modelDir(ctx).canonicalFile
        require(file.isFile && file.extension.equals("gguf", true) &&
            (file.path == root.path || file.path.startsWith(root.path + File.separator))) {
            "Model harus berada di penyimpanan NeuroN dan berformat .gguf"
        }
        val active = ProjectStore.load(ctx).files.modelPath
        require(file.absolutePath != active) { "Nonaktifkan model sebelum menghapusnya" }
        check(file.delete()) { "Model gagal dihapus" }
        modelSourceFile(file).delete()
        privacySidecar(file).delete()
        return mapOf("ok" to true, "path" to file.absolutePath)
    }

    private fun modelFile(ctx: Context, path: String): File {
        val file = File(path).canonicalFile
        val root = modelDir(ctx).canonicalFile
        require(file.isFile && file.extension.equals("gguf", true) && (file.path == root.path || file.path.startsWith(root.path + File.separator))) {
            "Model harus berada di penyimpanan NeuroN dan berformat .gguf"
        }
        return file
    }

    private fun renameLocalModel(ctx: Context, path: String, rawName: String): Map<String, Any> {
        val file = modelFile(ctx, path)
        val name = rawName.trim().replace(Regex("[^A-Za-z0-9._-]"), "_").removeSuffix(".gguf") + ".gguf"
        require(name.length > 5 && name != ".gguf") { "Nama model tidak valid" }
        val target = File(file.parentFile, name)
        require(!target.exists()) { "Nama model sudah digunakan" }
        check(file.renameTo(target)) { "Model gagal di-rename" }
        val source = modelSourceFile(file)
        if (source.exists()) source.renameTo(modelSourceFile(target))
        val p = ProjectStore.load(ctx)
        if (p.files.modelPath == file.absolutePath) ProjectStore.save(ctx, p.copy(files = p.files.copy(modelPath = target.absolutePath)))
        return mapOf("ok" to true, "path" to target.absolutePath, "name" to target.name)
    }

    private fun verifyLocalModel(ctx: Context, path: String): Map<String, Any> {
        val file = modelFile(ctx, path)
        val sha = HfClient().sha256(file)
        return mapOf("ok" to true, "valid" to true, "size" to file.length(), "sha256" to sha, "path" to file.absolutePath)
    }

    private fun exportLocalModelMetadata(ctx: Context, path: String): Map<String, Any> {
        val file = modelFile(ctx, path)
        val sha = HfClient().sha256(file)
        return mapOf("name" to file.name, "path" to file.absolutePath, "size" to file.length(), "sha256" to sha, "modified" to file.lastModified(), "format" to "GGUF")
    }

    private fun deviceHealth(ctx: Context, modelSize: Long): Map<String, Any> {
        val health = DeviceHealth.inspect(ctx, modelSize)
        return mapOf(
            "totalRam" to health.totalRamBytes,
            "availableRam" to health.availableRamBytes,
            "freeStorage" to health.freeStorageBytes,
            "cpuCores" to health.cpuCores,
            "abi" to health.abi,
            "sdk" to health.sdk,
            "lowRamDevice" to health.lowRamDevice,
            "modelSize" to health.modelSizeBytes,
            "recommendedMaxModel" to health.recommendedMaxModelBytes,
            "warnings" to health.warnings,
        )
    }

    private fun activateLocalModel(ctx: Context, path: String): Map<String, Any> {
        val file = File(path).canonicalFile
        val root = modelDir(ctx).canonicalFile
        require(file.isFile && file.extension.equals("gguf", true) &&
            (file.path == root.path || file.path.startsWith(root.path + File.separator))) {
            "Model harus berada di penyimpanan NeuroN dan berformat .gguf"
        }
        require(!LoraAdapter.isAdapter(file)) { "${file.name} adalah adapter LoRA, bukan model dasar. Pasang lewat Lainnya → LoRA." }
        val p = ProjectStore.load(ctx)
        ProjectStore.save(ctx, p.copy(files = p.files.copy(modelPath = file.absolutePath)))
        return mapOf("path" to file.absolutePath, "nativeAvailable" to LlamaCppEngine.available)
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
        val p = ProjectStore.load(ctx)
        require(p.knowledge.knowledgeFiles.isNotEmpty()) { "Tambahkan dokumen sebelum membuat indeks" }
        val engine = EngineHub.ensure(p)
        val store = SqliteVectorStore(ctx, File(ctx.filesDir, "rag/knowledge.db"))
        val report = RagPipeline(engine, store, p.knowledge, FileParser(ctx), "${p.engine.mode}:${p.files.modelPath}").sync()
        mapOf("indexed" to report.indexed, "skipped" to report.skipped, "chunks" to store.count(), "failed" to report.failed)
    }

    private fun hfSearch(ctx: Context, query: String, scope: String): List<Map<String, Any?>> = runBlocking(Dispatchers.IO) {
        require(query.isNotBlank()) { "Masukkan kata pencarian" }
        val filter = if (scope == "gguf") "gguf" else null
        HfClient(HfPrefs(ctx).token).search(query, filter = filter, limit = 50).map {
            mapOf("id" to it.id, "downloads" to it.downloads, "likes" to it.likes, "pipeline" to it.pipeline_tag, "gguf" to it.tags.any { tag -> tag.equals("gguf", true) })
        }
    }

    private fun hfFiles(ctx: Context, repo: String): List<Map<String, Any?>> = runBlocking(Dispatchers.IO) {
        val client = HfClient(HfPrefs(ctx).token)
        val sizes = runCatching { client.fileSizes(repo) }.getOrDefault(emptyMap())
        client.detail(repo).siblings.map {
            mapOf("name" to it.rfilename, "size" to (it.size ?: sizes[it.rfilename] ?: 0L), "gguf" to it.rfilename.endsWith(".gguf", true))
        }
    }

    private fun hfRevision(ctx: Context, repo: String): Map<String, String> = runBlocking(Dispatchers.IO) {
        require(repo.matches(Regex("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"))) { "ID repo tidak valid" }
        mapOf("repo" to repo, "revision" to HfClient(HfPrefs(ctx).token).revision(repo))
    }

    private fun modelSourceFile(model: File) = File(model.parentFile, model.name + ".neuron.json")

    private fun trackLocalModelSource(ctx: Context, path: String, repo: String, revision: String): Map<String, Any> {
        val model = modelFile(ctx, path)
        require(repo.matches(Regex("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"))) { "ID repo tidak valid" }
        require(revision.matches(Regex("[a-fA-F0-9]{7,64}"))) { "Revision Hugging Face tidak valid" }
        modelSourceFile(model).writeText(JSONObject().put("repo", repo).put("revision", revision).put("sha256", HfClient().sha256(model)).toString())
        return mapOf("ok" to true, "repo" to repo, "revision" to revision)
    }

    private fun checkLocalModelUpdate(ctx: Context, path: String): Map<String, Any?> = runBlocking(Dispatchers.IO) {
        val model = modelFile(ctx, path)
        val sidecar = modelSourceFile(model)
        require(sidecar.isFile) { "Asal Hugging Face belum ditautkan ke model ini" }
        val source = JSONObject(sidecar.readText())
        val repo = source.optString("repo")
        val installed = source.optString("revision")
        val latest = HfClient(HfPrefs(ctx).token).revision(repo)
        mapOf("repo" to repo, "installedRevision" to installed, "latestRevision" to latest, "updateAvailable" to (latest.isNotBlank() && latest != installed))
    }

    private fun hfDownload(ctx: Context, repo: String, file: String): Map<String, Any?> = runBlocking(Dispatchers.IO) {
        require(repo.matches(Regex("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"))) { "ID repo tidak valid" }
        require(isSafeHfPath(file)) { "Jalur file Hugging Face tidak valid" }
        val base = ctx.getExternalFilesDir("models") ?: File(ctx.filesDir, "models")
        val result = HfClient(HfPrefs(ctx).token).downloadFiles(repo, listOf(file), base).first()
        check(result.ok) { result.error ?: "Unduhan gagal" }
        val path = File(HfClient.targetDir(base, repo), file).absolutePath
        if (file.endsWith(".gguf", true)) {
            val p = ProjectStore.load(ctx)
            ProjectStore.save(ctx, p.copy(files = p.files.copy(modelPath = path)))
        }
        mapOf("path" to path, "bytes" to result.bytes, "verified" to result.verified, "runnable" to file.endsWith(".gguf", true))
    }

    /** Memulai unduhan WorkManager agar Flutter dapat menampilkan progres byte dan membatalkan. */
    private fun hfStartDownload(ctx: Context, repo: String, file: String, revision: String = ""): Map<String, Any> {
        require(repo.matches(Regex("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"))) { "ID repo tidak valid" }
        require(isSafeHfPath(file)) { "Jalur file Hugging Face tidak valid" }
        require(revision.isEmpty() || revision.matches(Regex("[a-fA-F0-9]{7,64}"))) { "Revision Hugging Face tidak valid" }
        val id = HfDownloadWorker.enqueue(ctx, repo, listOf(file), revision)
        return mapOf("id" to id.toString(), "repo" to repo, "file" to file)
    }

    private fun hfStartModelDownload(ctx: Context, repo: String, rawFiles: List<*>, revision: String = ""): Map<String, Any> {
        require(revision.isEmpty() || revision.matches(Regex("[a-fA-F0-9]{7,64}"))) { "Revision Hugging Face tidak valid" }
        require(repo.matches(Regex("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"))) { "ID repo tidak valid" }
        val files = rawFiles.map { it as? String ?: error("Daftar file model tidak valid") }.distinct()
        require(files.isNotEmpty() && files.all(::isSafeHfPath)) { "Daftar file model tidak valid" }
        val id = HfDownloadWorker.enqueue(ctx, repo, files, revision)
        return mapOf("id" to id.toString(), "repo" to repo, "files" to files, "count" to files.size)
    }

    private fun isSafeHfPath(path: String): Boolean = path.isNotBlank() &&
        !path.startsWith('/') && !path.contains('\\') && path.none { it.isISOControl() } &&
        path.split('/').all { it.isNotBlank() && it != "." && it != ".." }

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
            "modelDone" to p.getLong(HfDownloadWorker.KEY_MODEL_DONE, 0L),
            "modelTotal" to p.getLong(HfDownloadWorker.KEY_MODEL_TOTAL, -1L),
            "speed" to p.getLong(HfDownloadWorker.KEY_SPEED, 0L),
            "eta" to p.getLong(HfDownloadWorker.KEY_ETA, -1L),
            "path" to (out.getString(HfDownloadWorker.KEY_OUT) ?: ""),
            "modelPath" to (out.getString(HfDownloadWorker.KEY_MODEL) ?: ""),
            "error" to (out.getString(HfDownloadWorker.KEY_ERROR) ?: ""),
        )
    }

    private fun hfCancelDownload(ctx: Context, rawId: String): Map<String, Any> {
        val id = UUID.fromString(rawId)
        WorkManager.getInstance(ctx).cancelWorkById(id)
        HfDownloadWorker.forget(ctx, id)
        return mapOf("ok" to true)
    }

    private fun hfPauseDownload(ctx: Context, rawId: String): Map<String, Any> {
        val id = UUID.fromString(rawId)
        return mapOf("ok" to HfDownloadWorker.pause(ctx, id), "id" to rawId, "state" to "paused")
    }

    private fun hfResumeDownload(ctx: Context, rawId: String): Map<String, Any> {
        val id = UUID.fromString(rawId)
        val resumed = HfDownloadWorker.resume(ctx, id) ?: error("Request download tidak ditemukan; mulai ulang unduhan")
        return mapOf("ok" to true, "id" to resumed.toString(), "state" to "enqueued")
    }

    private fun copilotSuggest(ctx: Context, complaint: String, sample: String, focus: String?): Map<String, Any?> = runBlocking(Dispatchers.IO) {
        require(complaint.isNotBlank()) { "Jelaskan masalah yang ingin diperbaiki" }
        val project = ProjectStore.load(ctx)
        val brain = CopilotAgent(EngineFactory.wrap(EngineHub.ensure(project), project))
        val s = brain.suggest(project, complaint, sample, focus)
        mapOf("reason" to s.reason, "changes" to s.changes.map { c -> mapOf("path" to c.path, "oldText" to c.oldText, "newText" to c.newText, "error" to c.error, "reason" to c.reason) })
    }

    /** Muat model aktif ke memori sekarang (tanpa menunggu pesan chat pertama). */
    private fun runModel(ctx: Context): Map<String, Any?> = runBlocking(Dispatchers.IO) {
        val project = ProjectStore.load(ctx)
        if (project.files.modelPath.isBlank()) throw EngineException(EngineErrorKind.MODEL, "Belum ada model lokal aktif")
        val t0 = System.nanoTime()
        val engine = EngineHub.ensure(project)
        val warnings = (engine as? LlamaCppEngine)?.loadWarnings ?: emptyList()
        mapOf("ok" to true, "loaded" to EngineHub.isLoaded, "ms" to (System.nanoTime() - t0) / 1_000_000, "warnings" to warnings)
    }

    /** Lepas model dari memori (RAM kembali bebas). Dimuat ulang otomatis saat dipakai lagi. */
    private fun unloadModel(): Map<String, Any?> = runBlocking(Dispatchers.IO) {
        EngineHub.unload()
        mapOf("ok" to true, "loaded" to EngineHub.isLoaded)
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

    // ---------- Editor metadata GGUF (di perangkat, tanpa server) ----------

    /** Status satu operasi tulis GGUF. Hanya satu yang boleh berjalan; UI membaca kemajuan lewat ggufProgress. */
    private object GgufJob {
        @Volatile var running = false
        @Volatile var done = 0L
        @Volatile var total = 0L
        @Volatile var cancel = false
        fun snapshot(): Map<String, Any> = mapOf("running" to running, "done" to done, "total" to total)
    }

    private fun ggufDisplay(e: GgufEntry): String? = GgufReader.format(e.type, e.value)

    /** Tabel tensor + pemeriksaan integritas. Bila tabel rusak, header tetap bisa dilihat dan masalahnya dilaporkan. */
    private fun ggufReport(file: File, g: GgufFile): Pair<GgufReport?, String?> =
        try {
            GgufReader.analyze(g, GgufReader.readTensors(file, g)) to null
        } catch (e: GgufException) {
            null to (e.message ?: "Tabel tensor tidak terbaca")
        }

    /**
     * Baca model secara total: seluruh key metadata (termasuk ukuran array seperti daftar token), seluruh tabel tensor,
     * jumlah parameter, ukuran per tipe kuantisasi, dan pemeriksaan bahwa semua data tensor benar-benar ada di berkas.
     */
    private fun ggufInspect(ctx: Context, path: String): Map<String, Any?> {
        val file = modelFile(ctx, path)
        val g = GgufReader.read(file)
        val (report, tableError) = ggufReport(file, g)
        val entries = g.entries.map { e ->
            val reason = GgufEditor.protectionReason(e.key, e)
            mapOf(
                "key" to e.key,
                "type" to e.type.label,
                "elemType" to e.elemType?.label,
                "count" to e.arrayCount,
                "value" to ggufDisplay(e),
                "editable" to (e.editable && reason == null),
                "viewable" to (e.type == GgufType.ARRAY && e.elemType != GgufType.ARRAY),
                "note" to (reason ?: if (e.type != GgufType.ARRAY && e.value == null) "Nilai terlalu besar untuk diedit di sini." else ""),
            )
        }
        val fileType = g.entry("general.file_type")?.value as? Long
        val issues = (report?.issues ?: emptyList()) + listOfNotNull(tableError)
        return mapOf(
            "path" to file.absolutePath, "name" to file.name, "size" to file.length(),
            "version" to g.version, "tensorCount" to g.tensorCount, "alignment" to g.alignment,
            "dataOffset" to g.dataOffset, "dataBytes" to (g.fileSize - g.dataOffset),
            "tokenCount" to g.tokenCount, "entries" to entries,
            "fileType" to fileType, "fileTypeName" to GgmlTypes.fileTypeName(fileType),
            "params" to report?.totalParams, "tensorBytes" to report?.totalBytes, "layers" to report?.layers,
            "byType" to report?.byType?.map { mapOf("type" to it.type, "count" to it.count, "bytes" to it.bytes, "params" to it.params) },
            "issues" to issues,
            "complete" to (report != null && issues.isEmpty()),
        )
    }

    /** Halaman tabel tensor: [query] memfilter nama (huruf kecil/besar diabaikan); [limit] dibatasi 500. */
    private fun ggufTensors(ctx: Context, path: String, query: String, offset: Int, limit: Int): Map<String, Any?> {
        val file = modelFile(ctx, path)
        val g = GgufReader.read(file)
        val all = GgufReader.readTensors(file, g)
        val q = query.trim()
        val matched = if (q.isEmpty()) all else all.filter { it.name.contains(q, ignoreCase = true) }
        val from = offset.coerceIn(0, matched.size)
        val page = matched.subList(from, minOf(matched.size, from + limit.coerceIn(1, 500)))
        return mapOf(
            "total" to all.size, "matched" to matched.size, "offset" to from,
            "items" to page.map {
                mapOf("name" to it.name, "shape" to it.dims, "type" to it.typeName, "bytes" to it.bytes, "params" to it.elements, "offset" to it.offset)
            },
        )
    }

    /** Halaman isi array metadata (mis. tokenizer.ggml.tokens): [limit] dibatasi 500. */
    private fun ggufArray(ctx: Context, path: String, key: String, offset: Long, limit: Int): Map<String, Any?> {
        val file = modelFile(ctx, path)
        val g = GgufReader.read(file)
        val entry = g.entry(key) ?: throw IllegalArgumentException("Key tidak ditemukan: $key")
        val from = offset.coerceIn(0L, entry.arrayCount)
        val items = GgufReader.readArray(file, entry, from, limit.coerceIn(1, 500))
        return mapOf("key" to key, "elemType" to entry.elemType?.label, "count" to entry.arrayCount, "offset" to from, "items" to items)
    }

    /**
     * Simpan perubahan metadata sebagai salinan baru "<nama>-edited-<waktu>.gguf" di folder model.
     * Model asli tidak diubah. Butuh ruang bebas sebesar model; data bobot disalin apa adanya.
     */
    private fun ggufSave(ctx: Context, path: String, rawEdits: List<*>, activate: Boolean): Map<String, Any?> {
        val src = modelFile(ctx, path)
        run {
            val g = GgufReader.read(src)
            val (report, _) = ggufReport(src, g)
            require(report == null || report.issues.none { it.contains("melewati akhir berkas") }) {
                "Model ini terpotong (unduhan belum lengkap), tidak bisa disalin. Unduh ulang lewat Model Hub."
            }
        }
        val edits = rawEdits.mapNotNull { it as? Map<*, *> }.map { m ->
            GgufEdit(key = str(m, "key"), delete = m["delete"] == true, type = GgufType.byLabel(str(m, "type")), value = str(m, "value"))
        }
        synchronized(GgufJob) {
            check(!GgufJob.running) { "Operasi GGUF lain masih berjalan" }
            GgufJob.running = true; GgufJob.done = 0; GgufJob.total = 0; GgufJob.cancel = false
        }
        try {
            val base = src.name.removeSuffix(".gguf").replace(Regex("-edited-\\d+$"), "")
            val dst = File(src.parentFile, "$base-edited-${System.currentTimeMillis()}.gguf")
            val info = GgufEditor.rewrite(src, dst, edits, { d, t -> GgufJob.done = d; GgufJob.total = t }, { GgufJob.cancel })
            if (activate) activateLocalModel(ctx, dst.absolutePath)
            return mapOf(
                "ok" to true, "path" to dst.absolutePath, "name" to dst.name, "size" to dst.length(),
                "activated" to activate, "entries" to info.entries.size,
            )
        } catch (e: GgufCancelled) {
            throw IllegalStateException("Penyimpanan dibatalkan; tidak ada berkas yang dibuat")
        } finally {
            GgufJob.running = false
        }
    }

    private fun str(a: Map<*, *>, key: String): String = a[key] as? String ?: ""

    private fun strList(a: Map<*, *>, key: String): List<String> =
        (a[key] as? List<*>)?.map { it.toString().trim() }?.filter { it.isNotEmpty() } ?: emptyList()
}
