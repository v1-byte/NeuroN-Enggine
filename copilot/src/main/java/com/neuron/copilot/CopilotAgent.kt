package com.neuron.copilot

import com.neuron.engine.ChatMessage
import com.neuron.engine.EngineHub
import com.neuron.engine.InferenceEngine
import com.neuron.model.AiProject
import com.neuron.model.ChatParams
import com.neuron.project.VirtualTree
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*

data class CopilotSuggestion(val reason: String, val changes: List<FileChange>, val rawReply: String)

/**
 * Copilot memperbaiki konfigurasi project.
 * Alur: konteks file -> balasan JSON berisi patch per file -> validasi lewat VirtualTree.write
 * -> diff untuk ditinjau -> user terima/tolak per file. Copilot tidak pernah menulis sendiri: hasil hanya berlaku lewat [applyChange].
 */
class CopilotAgent(private val brain: InferenceEngine) {

    companion object {
        /** File yang TIDAK boleh diubah Copilot: kunci API, kasus eval (agar tidak "curang"), dan file model/training. */
        val NOT_ALLOWED = setOf(
            "engine/api.json", "eval/cases.json",
            "model/quantization.json", "model/lora.json", "model/ops.json",
            "training/train.json",
        )
        val ALLOWED_PATHS: List<String> = VirtualTree.paths.filter { it !in NOT_ALLOWED }

        /** File teks biasa: harus memakai "content" berupa teks lengkap. */
        val TEXT_PATHS = setOf("chat/system_prompt.md", "model/Modelfile", "model/chat_template.jinja")

        /** Isi file ini dikirim penuh ke model (hemat context window HP). Yang lain hanya namanya. */
        val FOCUS_PATHS = listOf("chat/params.json", "chat/system_prompt.md", "knowledge/rag.json", "hardware/engine.json")

        private const val SYSTEM_PROMPT = """Kamu Copilot untuk men-tuning model AI. Balas HANYA satu objek JSON, tanpa teks atau markdown lain:
{"reason":"alasan singkat dalam bahasa Indonesia","changes":[{"path":"...","merge":{...}}]}
Aturan:
- Untuk file JSON: isi "merge" dengan HANYA field yang diubah (JSON merge patch; null menghapus field).
- Untuk file teks (chat/system_prompt.md, model/Modelfile, model/chat_template.jinja): isi "content" dengan teks lengkap baru.
- "path" harus persis salah satu path yang diberikan.
- Ubah sesedikit mungkin. Jangan mengubah file model kecuali diminta.
- Jika tidak perlu perubahan, balas "changes":[]"""

        /**
         * Terapkan satu usulan ke project. Gagal bila isi file sudah berubah sejak saran dibuat
         * (user mengedit file itu) atau bila validasi skema gagal.
         */
        fun applyChange(project: AiProject, change: FileChange): Result<AiProject> {
            val text = change.newText ?: return Result.failure(IllegalStateException(change.error ?: "usulan kosong"))
            if (VirtualTree.read(project, change.path) != change.oldText) {
                return Result.failure(IllegalStateException("file ${change.path} sudah berubah sejak saran dibuat; minta saran ulang"))
            }
            return VirtualTree.write(project, change.path, text).mapCatching { updated ->
                val bad = Consistency.introduced(project, updated)
                if (bad.isNotEmpty()) throw IllegalStateException(bad.first())
                updated
            }
        }
    }

    suspend fun suggest(project: AiProject, complaint: String, sampleOutput: String, focus: String? = null): CopilotSuggestion {
        val raw = EngineHub.gate.withLock {
            brain.chat(
                listOf(ChatMessage("user", buildUserMessage(project, complaint, sampleOutput, focus))),
                ChatParams(systemPrompt = SYSTEM_PROMPT, temperature = 0.2f, maxTokens = 900),
            ).toList().joinToString("")
        }
        val obj = extractJsonObject(raw)
        val reason = ((obj["reason"] as? JsonPrimitive)?.contentOrNull) ?: ""
        val items = (obj["changes"] as? JsonArray).orEmpty()
        // Satu path hanya satu usulan (yang terakhir), supaya tidak saling menimpa.
        val changes = items
            .mapNotNull { el -> (el as? JsonObject)?.let { toChange(project, it) } }
            .groupBy { it.path }
            .values
            .map { it.last() }
        return CopilotSuggestion(reason, changes, raw)
    }

    private fun buildUserMessage(project: AiProject, complaint: String, sample: String, focus: String?): String = buildString {
        val shown = (FOCUS_PATHS + listOfNotNull(focus)).filter { it in ALLOWED_PATHS }.distinct()
        append("Keluhan: ").append(complaint.trim().take(400)).append('\n')
        if (sample.isNotBlank()) append("Contoh output bermasalah:\n").append(sample.trim().take(600)).append('\n')
        if (focus != null && focus in ALLOWED_PATHS) append("Pengguna sedang membuka file: ").append(focus).append(" (utamakan file ini bila relevan)\n")
        append("\nIsi file fokus saat ini:\n")
        shown.forEach { path ->
            val t = VirtualTree.read(project, path)
            append("=== ").append(path).append(" ===\n")
            append(if (t.length > 900) t.take(900) + "\n…[dipotong]" else t).append('\n')
        }
        append("\nFile lain yang boleh diubah (isinya tidak ditampilkan): ")
        append(ALLOWED_PATHS.filter { it !in shown }.joinToString(", ")).append('\n')
    }

    private fun toChange(project: AiProject, o: JsonObject): FileChange? {
        val path = (o["path"] as? JsonPrimitive)?.contentOrNull ?: return null
        val reason = ((o["reason"] as? JsonPrimitive)?.contentOrNull) ?: ""
        val old = if (path in VirtualTree.paths) VirtualTree.read(project, path) else ""
        if (path !in ALLOWED_PATHS) return FileChange(path, old, null, "file ini tidak boleh diubah Copilot", reason)

        val built = runCatching {
            if (path in TEXT_PATHS) {
                (o["content"] as? JsonPrimitive)?.contentOrNull ?: error("file teks butuh field \"content\" berupa string")
            } else {
                val merge = (o["merge"] ?: o["content"]) as? JsonObject
                val text = (o["content"] as? JsonPrimitive)?.contentOrNull
                when {
                    merge != null -> mergeJsonText(old, merge)
                    text != null -> text
                    else -> error("file JSON butuh field \"merge\" berupa objek")
                }
            }
        }
        val newText = built.getOrNull()
        val err: String? = if (built.isFailure) {
            built.exceptionOrNull()?.message?.lineSequence()?.firstOrNull() ?: "patch tidak valid"
        } else {
            val written = VirtualTree.write(project, path, built.getOrThrow())
            written.exceptionOrNull()?.message?.lineSequence()?.firstOrNull()
                ?: written.getOrNull()?.let { Consistency.introduced(project, it).firstOrNull() }
        }
        return FileChange(path, old, newText, err, reason)
    }
}
