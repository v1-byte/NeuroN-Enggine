package com.neuron.hf

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.Dispatcher
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.RandomAccessFile
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong

@Serializable data class HfModel(val id: String, val downloads: Int = 0, val likes: Int = 0, val pipeline_tag: String? = null, val tags: List<String> = emptyList())
@Serializable data class HfSibling(val rfilename: String, val size: Long? = null)
@Serializable data class HfModelDetail(val id: String, val siblings: List<HfSibling> = emptyList())
@Serializable data class HfLfs(val sha256: String? = null, val size: Long? = null)
@Serializable data class HfTreeEntry(val type: String = "", val path: String = "", val size: Long? = null, val lfs: HfLfs? = null)

/** Hasil satu file dalam unduhan. verified = true jika checksum SHA-256 dari Hub dicocokkan. */
data class DownloadResult(val file: String, val bytes: Long, val ok: Boolean, val error: String? = null, val verified: Boolean = false)

/** Pencarian & unduh dari Hugging Face Hub. Token opsional untuk model gated/privat. */
class HfClient(
    private val token: String? = null,
    private val http: OkHttpClient = OkHttpClient.Builder().dispatcher(Dispatcher().apply {
        maxRequests = 16
        maxRequestsPerHost = 16
    }).build(),
) {
    private val json = Json { ignoreUnknownKeys = true }

    private fun req(url: String, rangeFrom: Long? = null, rangeTo: Long? = null) = Request.Builder().url(url).apply {
        token?.let { header("Authorization", "Bearer $it") }
        rangeFrom?.let { header("Range", "bytes=$it-${rangeTo ?: ""}") }
    }.build()

    private fun encQuery(s: String) = URLEncoder.encode(s, "UTF-8")
    private fun encPath(s: String) = s.split("/").joinToString("/") { URLEncoder.encode(it, "UTF-8").replace("+", "%20") }

    private fun httpError(code: Int): String = when (code) {
        401, 403 -> "Akses ditolak ($code): model gated/privat, isi token Hugging Face"
        404 -> "Tidak ditemukan (404)"
        else -> "HTTP $code"
    }

    /** Panggilan JSON blocking; selalu dipanggil dari Dispatchers.IO. */
    private fun <T> getJson(url: String, decode: (String) -> T): T =
        http.newCall(req(url)).execute().use { r ->
            check(r.isSuccessful) { httpError(r.code) }
            decode(checkNotNull(r.body) { "body kosong" }.string())
        }

    /** filter contoh: "gguf", "text-generation", "onnx" */
    suspend fun search(query: String, filter: String? = null, sort: String = "downloads", limit: Int = 30): List<HfModel> = withContext(Dispatchers.IO) {
        val url = buildString {
            append("https://huggingface.co/api/models?search=").append(encQuery(query))
            append("&sort=").append(encQuery(sort)).append("&direction=-1&limit=").append(limit)
            filter?.let { append("&filter=").append(encQuery(it)) }
        }
        getJson(url) { json.decodeFromString<List<HfModel>>(it) }
    }

    suspend fun detail(repoId: String): HfModelDetail = withContext(Dispatchers.IO) {
        getJson("https://huggingface.co/api/models/$repoId") { json.decodeFromString<HfModelDetail>(it) }
    }

    /** Checksum SHA-256 per file LFS dari tree API. Catatan: repo yang sangat besar bisa terpotong (paginasi belum ditangani). */
    suspend fun fileChecksums(repoId: String): Map<String, String> = withContext(Dispatchers.IO) {
        getJson("https://huggingface.co/api/models/$repoId/tree/main?recursive=true") { json.decodeFromString<List<HfTreeEntry>>(it) }
            .mapNotNull { e -> e.lfs?.sha256?.let { e.path to it } }
            .toMap()
    }

    suspend fun fileSizes(repoId: String): Map<String, Long> = withContext(Dispatchers.IO) {
        getJson("https://huggingface.co/api/models/$repoId/tree/main?recursive=true") { json.decodeFromString<List<HfTreeEntry>>(it) }
            .mapNotNull { entry -> entry.size?.let { entry.path to it } }
            .toMap()
    }

    /**
     * Unduh satu file dengan resume (HTTP Range). onProgress(bytesDone, total; total = -1 jika tidak diketahui).
     * Server mengabaikan Range (balas 200): file ditulis ulang dari awal. 416 (sudah lengkap): dianggap sukses.
     */
    suspend fun download(repoId: String, file: String, dest: File, onProgress: (Long, Long) -> Unit = { _, _ -> }) {
        withContext(Dispatchers.IO) {
            val url = "https://huggingface.co/$repoId/resolve/main/${encPath(file)}"
            dest.parentFile?.mkdirs()
            var start = if (dest.exists()) dest.length() else 0L
            http.newCall(req(url, if (start > 0) start else null)).execute().use { r ->
                if (r.code == 416) return@use
                check(r.isSuccessful) { httpError(r.code) }
                if (start > 0 && r.code != 206) start = 0L
                val body = checkNotNull(r.body) { "body kosong" }
                val len = body.contentLength()
                val total = if (len < 0) -1L else start + len
                RandomAccessFile(dest, "rw").use { raf ->
                    raf.setLength(start)
                    raf.seek(start)
                    val buf = ByteArray(1 shl 16)
                    var done = start
                    body.byteStream().use { ins ->
                        while (true) {
                            val n = ins.read(buf)
                            if (n < 0) break
                            raf.write(buf, 0, n)
                            done += n
                            onProgress(done, total)
                        }
                    }
                }
            }
        }
    }

    /**
     * Download segmented untuk GGUF besar. Memakai delapan koneksi paralel bila server
     * mendukung Range; fallback ke download biasa ditangani caller saat segmented gagal.
     * Kecepatan aktual tetap bergantung pada bandwidth, CDN, dan batas server.
     */
    private suspend fun downloadParallel(repoId: String, file: String, dest: File, total: Long, onProgress: (Long, Long) -> Unit) = coroutineScope {
        val url = "https://huggingface.co/$repoId/resolve/main/${encPath(file)}"
        val parts = 8.coerceAtMost(((total + 32L * 1024 * 1024 - 1) / (32L * 1024 * 1024)).toInt().coerceAtLeast(2))
        val done = AtomicLong(0L)
        dest.parentFile?.mkdirs()
        RandomAccessFile(dest, "rw").use { it.setLength(total) }
        (0 until parts).map { index ->
            async(Dispatchers.IO) {
                val start = total * index / parts
                val end = total * (index + 1) / parts - 1
                http.newCall(req(url, start, end)).execute().use { response ->
                    check(response.code == 206) { "Server tidak mendukung segmented download (HTTP ${response.code})" }
                    val body = checkNotNull(response.body) { "body kosong" }
                    RandomAccessFile(dest, "rw").use { raf ->
                        raf.seek(start)
                        body.byteStream().use { input ->
                            val buffer = ByteArray(1 shl 16)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                raf.write(buffer, 0, count)
                                onProgress(done.addAndGet(count.toLong()), total)
                            }
                        }
                    }
                }
            }
        }.awaitAll()
    }

    /** SHA-256 file dalam bentuk heksa huruf kecil. */
    fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { ins ->
            val buf = ByteArray(1 shl 16)
            while (true) { val n = ins.read(buf); if (n < 0) break; md.update(buf, 0, n) }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /** Cocokkan checksum; expected null/kosong = tidak ada referensi, dianggap lolos. */
    fun verify(f: File, expectedSha256: String?): Boolean =
        expectedSha256.isNullOrBlank() || sha256(f).equals(expectedSha256, ignoreCase = true)

    /** Ukuran (byte) dari daftar file; file tanpa ukuran dihitung 0. */
    fun totalBytes(detail: HfModelDetail, filter: (String) -> Boolean = { true }): Long =
        detail.siblings.filter { filter(it.rfilename) }.sumOf { it.size ?: 0L }

    /** Pastikan ruang kosong di [dir] cukup untuk [needed] byte, plus margin 5%. */
    fun hasSpace(dir: File, needed: Long): Boolean {
        dir.mkdirs()
        return dir.usableSpace >= needed + needed / 20
    }

    /**
     * Unduh file-file terpilih ke [baseDir]/[owner__name]/... dengan struktur folder asli.
     * Setiap file diverifikasi SHA-256 bila Hub menyediakannya. Berhenti di file pertama yang gagal.
     */
    suspend fun downloadFiles(
        repoId: String,
        files: List<String>,
        baseDir: File,
        onFile: (name: String, index: Int, count: Int) -> Unit = { _, _, _ -> },
        onProgress: (file: String, done: Long, total: Long) -> Unit = { _, _, _ -> },
    ): List<DownloadResult> {
        require(files.isNotEmpty()) { "Tidak ada file dipilih" }
        val detail = detail(repoId)
        val sizes = detail.siblings.associate { it.rfilename to (it.size ?: 0L) }
        val needed = files.sumOf { sizes[it] ?: 0L }
        check(needed == 0L || hasSpace(baseDir, needed)) { "Ruang penyimpanan tidak cukup (butuh ~${needed / 1_000_000} MB)" }
        // Checksum opsional: jika gagal diambil, unduhan tetap jalan tanpa verifikasi.
        val sums: Map<String, String> = try { fileChecksums(repoId) } catch (e: CancellationException) { throw e } catch (e: Exception) { emptyMap() }

        val target = targetDir(baseDir, repoId)
        val results = mutableListOf<DownloadResult>()
        files.forEachIndexed { i, name ->
            onFile(name, i + 1, files.size)
            val dest = File(target, name)
            try {
                val expectedSize = sizes[name] ?: 0L
                if (expectedSize >= 64L * 1024 * 1024) {
                    try {
                        downloadParallel(repoId, name, dest, expectedSize) { done, total -> onProgress(name, done, total) }
                    } catch (e: Exception) {
                        dest.delete()
                        download(repoId, name, dest) { done, total -> onProgress(name, done, total) }
                    }
                } else {
                    download(repoId, name, dest) { done, total -> onProgress(name, done, total) }
                }
                val expected = sums[name]
                if (!verify(dest, expected)) {
                    dest.delete()
                    results += DownloadResult(name, 0L, ok = false, error = "checksum SHA-256 tidak cocok")
                    return results
                }
                results += DownloadResult(name, dest.length(), ok = true, verified = expected != null)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                results += DownloadResult(name, dest.length(), ok = false, error = e.message ?: "gagal")
                return results
            }
        }
        return results
    }

    /** Unduh snapshot: semua file yang lolos [filter]. */
    suspend fun downloadRepo(repoId: String, baseDir: File, filter: (String) -> Boolean = { true }, onFile: (String, Int, Int) -> Unit = { _, _, _ -> }, onProgress: (String, Long, Long) -> Unit = { _, _, _ -> }): List<DownloadResult> {
        val names = detail(repoId).siblings.map { it.rfilename }.filter(filter)
        return downloadFiles(repoId, names, baseDir, onFile, onProgress)
    }

    companion object {
        /** Folder hasil unduhan satu repo: base/owner__name. */
        fun targetDir(base: File, repoId: String): File = File(base, repoId.replace("/", "__"))
    }
}
