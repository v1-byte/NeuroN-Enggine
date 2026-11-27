package com.neuron.copilot

import com.neuron.project.VirtualTree
import kotlinx.serialization.json.*

/** Satu usulan perubahan untuk satu file virtual. newText null = usulan tidak bisa dipakai (lihat error). */
data class FileChange(
    val path: String,
    val oldText: String,
    val newText: String?,
    val error: String? = null,
    val reason: String = "",
)

/** Satu baris hasil diff: ' ' sama, '+' ditambah, '-' dihapus. */
data class DiffLine(val kind: Char, val text: String)

/** JSON Merge Patch (RFC 7386): objek digabung rekursif, null menghapus field, nilai lain menggantikan. */
fun mergePatch(target: JsonElement, patch: JsonElement): JsonElement {
    if (patch !is JsonObject) return patch
    val out = ((target as? JsonObject) ?: JsonObject(emptyMap())).toMutableMap()
    for ((k, v) in patch) {
        if (v is JsonNull) {
            out.remove(k)
        } else {
            out[k] = mergePatch(out[k] ?: JsonNull, v)
        }
    }
    return JsonObject(out)
}

/** Terapkan merge patch ke teks JSON lama; hasil ditulis dengan format pretty seperti VirtualTree. */
fun mergeJsonText(old: String, patch: JsonObject): String =
    VirtualTree.json.encodeToString(JsonElement.serializer(), mergePatch(Json.parseToJsonElement(old), patch))

/** Diff per baris berbasis LCS. Untuk file yang sangat besar (matriks > 4 juta sel) cukup tampilkan hapus semua + tambah semua. */
fun lineDiff(a: String, b: String): List<DiffLine> {
    val x = a.lines()
    val y = b.lines()
    val n = x.size
    val m = y.size
    if (n.toLong() * m > 4_000_000L) return x.map { DiffLine('-', it) } + y.map { DiffLine('+', it) }
    val dp = Array(n + 1) { IntArray(m + 1) }
    for (i in n - 1 downTo 0) {
        for (j in m - 1 downTo 0) {
            dp[i][j] = if (x[i] == y[j]) dp[i + 1][j + 1] + 1 else maxOf(dp[i + 1][j], dp[i][j + 1])
        }
    }
    val out = ArrayList<DiffLine>()
    var i = 0
    var j = 0
    while (i < n && j < m) {
        when {
            x[i] == y[j] -> { out.add(DiffLine(' ', x[i])); i++; j++ }
            dp[i + 1][j] >= dp[i][j + 1] -> { out.add(DiffLine('-', x[i])); i++ }
            else -> { out.add(DiffLine('+', y[j])); j++ }
        }
    }
    while (i < n) { out.add(DiffLine('-', x[i])); i++ }
    while (j < m) { out.add(DiffLine('+', y[j])); j++ }
    return out
}

/** Ambil objek JSON pertama dari balasan model (toleran terhadap teks/markdown di sekelilingnya). */
fun extractJsonObject(raw: String): JsonObject {
    val s = raw.indexOf('{')
    val e = raw.lastIndexOf('}')
    require(s >= 0 && e > s) { "Balasan model tidak berisi objek JSON" }
    return Json.parseToJsonElement(raw.substring(s, e + 1)) as? JsonObject
        ?: throw IllegalArgumentException("Balasan model bukan objek JSON")
}
