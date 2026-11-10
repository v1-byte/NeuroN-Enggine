package com.neuron.train

import com.neuron.model.TrainMethod
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.math.roundToInt
import kotlin.random.Random

/** Ringkasan pemeriksaan dataset, ditampilkan sebelum training. */
data class DatasetReport(
    val format: String,         // "jsonl" | "json" | "csv" | "-"
    val totalRecords: Int,      // semua record yang terbaca (valid + tidak valid)
    val validRecords: Int,
    val errorCount: Int,        // jumlah semua error (bukan hanya yang ditampilkan)
    val errors: List<String>,   // maksimal DatasetImporter.MAX_ERRORS pertama
    val preview: List<String>,  // ringkasan record valid pertama
) {
    val ok: Boolean get() = validRecords > 0 && errorCount == 0
}

data class SplitResult(val trainFile: File, val valFile: File?, val trainCount: Int, val valCount: Int)

/**
 * Pemeriksaan, pratinjau, dan split dataset di perangkat.
 *  - jsonl & csv dibaca baris per baris (hemat memori).
 *  - json harus berupa array; dimuat penuh ke memori, dibatasi [maxJsonBytes].
 *  - csv hanya mendukung satu baris per record: baris yang memuat tanda kutip tidak seimbang ditolak.
 * Output split selalu JSONL (satu record per baris), format yang dibaca trainer di server.
 * Split deterministik: seed yang sama selalu menghasilkan pembagian yang sama.
 */
class DatasetImporter(private val maxJsonBytes: Long = 64L * 1024 * 1024) {

    companion object {
        const val MAX_ERRORS = 30
        const val MAX_PREVIEW = 3
        private val ROLES = setOf("system", "user", "assistant", "tool")
    }

    fun formatOf(file: File): String? = when (file.extension.lowercase()) {
        "jsonl" -> "jsonl"
        "json" -> "json"
        "csv" -> "csv"
        else -> null
    }

    /** Periksa seluruh file. Hanya error pertama yang disimpan, tetapi jumlahnya dihitung semua. */
    fun inspect(file: File, method: TrainMethod): DatasetReport {
        val fmt = formatOf(file) ?: return DatasetReport("-", 0, 0, 1, listOf("Format harus .jsonl / .json / .csv"), emptyList())
        if (!file.exists()) return DatasetReport(fmt, 0, 0, 1, listOf("File tidak ada"), emptyList())
        var total = 0
        var valid = 0
        var errCount = 0
        val errors = ArrayList<String>()
        val preview = ArrayList<String>()
        try {
            forEachRecord(file, fmt) { lineNo, obj, parseErr ->
                total++
                val err = parseErr ?: checkRecord(obj!!, method)
                if (err == null) {
                    valid++
                    if (preview.size < MAX_PREVIEW) preview.add(previewOf(obj!!))
                } else {
                    errCount++
                    if (errors.size < MAX_ERRORS) errors.add("baris $lineNo: $err")
                }
            }
        } catch (e: Exception) {
            errCount++
            errors.add("gagal membaca: ${e.message ?: e.javaClass.simpleName}")
        }
        return DatasetReport(fmt, total, valid, errCount, errors, preview)
    }

    /**
     * Bagi record valid menjadi train.jsonl dan val.jsonl di [outDir].
     * Jumlah val = round(valid * valRatio), minimal 1 bila rasio > 0 dan record >= 2.
     * Pemilihan dengan Random(seed) atas indeks, jadi tidak perlu memuat seluruh isi ke memori.
     */
    fun split(file: File, method: TrainMethod, valRatio: Double, seed: Long, outDir: File): SplitResult {
        require(valRatio in 0.0..0.5) { "valRatio harus 0..0.5" }
        val fmt = formatOf(file) ?: error("Format harus .jsonl / .json / .csv")
        outDir.mkdirs()

        // Pass 1: hitung record valid. Urutan dan aturan harus sama dengan pass 2.
        var validCount = 0
        forEachRecord(file, fmt) { _, obj, perr ->
            if (perr == null && checkRecord(obj!!, method) == null) validCount++
        }
        require(validCount >= 2) { "Butuh minimal 2 record valid (ada $validCount)" }

        val valTarget = if (valRatio <= 0.0) 0 else (validCount * valRatio).roundToInt().coerceIn(1, validCount - 1)
        val isVal = BooleanArray(validCount)
        val order = (0 until validCount).shuffled(Random(seed))
        for (k in 0 until valTarget) isVal[order[k]] = true

        // Pass 2: tulis ke file.
        val trainFile = File(outDir, "train.jsonl")
        val valFile = File(outDir, "val.jsonl")
        var i = 0
        var trainCount = 0
        var valCount = 0
        trainFile.bufferedWriter().use { tw ->
            valFile.bufferedWriter().use { vw ->
                forEachRecord(file, fmt) { _, obj, perr ->
                    if (perr == null && checkRecord(obj!!, method) == null) {
                        val line = obj.toString()
                        if (isVal[i]) {
                            vw.write(line); vw.newLine(); valCount++
                        } else {
                            tw.write(line); tw.newLine(); trainCount++
                        }
                        i++
                    }
                }
            }
        }
        if (valTarget == 0) valFile.delete()
        return SplitResult(trainFile, if (valTarget > 0) valFile else null, trainCount, valCount)
    }

    /** Aturan per record sesuai metode. Mengembalikan null bila valid, atau alasan singkat. */
    private fun checkRecord(o: JSONObject, method: TrainMethod): String? {
        fun str(k: String) = o.optString(k, "").trim()
        if (method == TrainMethod.DPO) {
            return when {
                str("prompt").isEmpty() -> "field prompt kosong/tidak ada"
                str("chosen").isEmpty() -> "field chosen kosong/tidak ada"
                str("rejected").isEmpty() -> "field rejected kosong/tidak ada"
                else -> null
            }
        }
        val msgs: JSONArray? = when (val m = o.opt("messages")) {
            is JSONArray -> m
            is String -> runCatching { JSONArray(m) }.getOrNull()
            else -> null
        }
        if (msgs != null) {
            if (msgs.length() == 0) return "messages kosong"
            var hasAssistant = false
            for (i in 0 until msgs.length()) {
                val m = msgs.optJSONObject(i) ?: return "messages[$i] bukan objek"
                val role = m.optString("role")
                if (role !in ROLES) return "messages[$i].role tidak dikenal: '$role'"
                if (m.optString("content").isBlank()) return "messages[$i].content kosong"
                if (role == "assistant") hasAssistant = true
            }
            return if (hasAssistant) null else "messages tidak punya balasan assistant"
        }
        val hasIn = str("instruction").isNotEmpty() || str("prompt").isNotEmpty()
        val hasOut = str("output").isNotEmpty() || str("response").isNotEmpty()
        return when {
            !hasIn -> "butuh field instruction atau prompt"
            !hasOut -> "butuh field output atau response (tidak kosong)"
            else -> null
        }
    }

    private fun previewOf(o: JSONObject): String {
        val msgs = o.opt("messages")
        val s = when {
            msgs is JSONArray -> (0 until msgs.length()).joinToString(" | ") { i ->
                val m = msgs.optJSONObject(i)
                "${m?.optString("role")}: ${m?.optString("content")}"
            }
            o.has("chosen") -> "prompt: ${o.optString("prompt")} → chosen: ${o.optString("chosen")}"
            else -> "${o.optString("instruction", o.optString("prompt"))} → ${o.optString("output", o.optString("response"))}"
        }
        return s.take(240)
    }

    /** Baca record satu per satu. visit(nomor baris, objek atau null, pesan error parsing atau null). */
    private fun forEachRecord(file: File, fmt: String, visit: (Int, JSONObject?, String?) -> Unit) {
        when (fmt) {
            "jsonl" -> file.bufferedReader().use { r ->
                var n = 0
                r.forEachLine { line ->
                    n++
                    if (line.isBlank()) return@forEachLine
                    val o = runCatching { JSONObject(line) }.getOrNull()
                    visit(n, o, if (o == null) "bukan JSON" else null)
                }
            }
            "json" -> {
                require(file.length() <= maxJsonBytes) {
                    "file .json terlalu besar (> ${maxJsonBytes / (1024 * 1024)} MB). Ubah ke .jsonl"
                }
                val arr = JSONArray(file.readText())
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i)
                    visit(i + 1, o, if (o == null) "bukan objek" else null)
                }
            }
            "csv" -> file.bufferedReader().use { r ->
                val header = r.readLine()?.let { splitCsv(it) } ?: return@use
                var n = 1
                r.forEachLine { line ->
                    n++
                    if (line.isBlank()) return@forEachLine
                    if (line.count { it == '"' } % 2 == 1) {
                        visit(n, null, "tanda kutip tidak seimbang (baris multiline belum didukung)")
                        return@forEachLine
                    }
                    val vals = splitCsv(line)
                    if (vals.size != header.size) {
                        visit(n, null, "jumlah kolom ${vals.size}, seharusnya ${header.size}")
                        return@forEachLine
                    }
                    val o = JSONObject()
                    header.forEachIndexed { i, k -> o.put(k.trim(), vals[i]) }
                    visit(n, o, null)
                }
            }
            else -> error("format tidak dikenal: $fmt")
        }
    }

    /** Pemisah CSV sederhana dengan tanda kutip ganda ("" = kutip literal). */
    private fun splitCsv(line: String): List<String> {
        val out = ArrayList<String>()
        val cur = StringBuilder()
        var quoted = false
        var i = 0
        while (i < line.length) {
            val c = line[i]
            when {
                quoted && c == '"' && i + 1 < line.length && line[i + 1] == '"' -> { cur.append('"'); i++ }
                c == '"' -> quoted = !quoted
                c == ',' && !quoted -> { out.add(cur.toString()); cur.clear() }
                else -> cur.append(c)
            }
            i++
        }
        out.add(cur.toString())
        return out
    }
}
