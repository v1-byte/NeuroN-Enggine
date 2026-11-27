package com.neuron.hf

import java.io.File
import java.security.MessageDigest

/** Hasil satu file dalam unduhan. verified = true jika checksum SHA-256 dari Hub dicocokkan. */
data class DownloadResult(val file: String, val bytes: Long, val ok: Boolean, val error: String? = null, val verified: Boolean = false)

/**
 * Logika berkas unduhan tanpa dependensi jaringan/Android (bisa dites sebagai JUnit biasa).
 *
 * Aturan: data diunduh ke "<nama>.part" dan baru diganti nama menjadi "<nama>" setelah checksum cocok.
 * Dengan begitu berkas bernama akhir (mis. model .gguf) SELALU utuh; unduhan yang dijeda atau gagal hanya
 * meninggalkan ".part" yang bisa dilanjutkan, dan tidak pernah tampil sebagai model terpasang.
 */
object HfFiles {
    fun partOf(dest: File): File = File(dest.path + ".part")

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

    /** Ganti [dest] dengan [part] secara utuh. Melempar bila gagal, dan [part] tetap ada. */
    fun promote(part: File, dest: File) {
        if (dest.exists() && !dest.delete()) throw IllegalStateException("Gagal mengganti file lama: ${dest.name}")
        if (!part.renameTo(dest)) throw IllegalStateException("Gagal menyelesaikan unduhan: ${dest.name}")
    }

    /**
     * Pastikan [dest] terunduh utuh dan terverifikasi. [fetch] mengisi (atau melanjutkan) berkas ".part" yang diberikan.
     *
     * - [dest] sudah ada dan cocok checksum: dipakai apa adanya (tanpa unduh ulang).
     * - [dest] sudah ada tetapi tidak cocok (rusak, atau sisa skema lama yang menulis langsung ke nama akhir): dibuang.
     * - Setelah [fetch], checksum diperiksa. Bila tidak cocok dan ".part" tadi hasil lanjutan, kemungkinan sisa dari
     *   revision lain; dibuang dan diulang sekali dari awal. Bila tetap tidak cocok, gagal dan ".part" dihapus.
     * - Exception dari [fetch] diteruskan; ".part" dibiarkan supaya bisa dilanjutkan.
     */
    suspend fun fetchVerified(name: String, dest: File, expectedSha256: String?, fetch: suspend (part: File) -> Unit): DownloadResult {
        val part = partOf(dest)
        dest.parentFile?.mkdirs()
        if (dest.isFile && !expectedSha256.isNullOrBlank()) {
            if (verify(dest, expectedSha256)) {
                part.delete()
                return DownloadResult(name, dest.length(), ok = true, verified = true)
            }
            dest.delete()
        }
        while (true) {
            val resumed = part.isFile && part.length() > 0
            fetch(part)
            if (verify(part, expectedSha256)) {
                promote(part, dest)
                return DownloadResult(name, dest.length(), ok = true, verified = !expectedSha256.isNullOrBlank())
            }
            part.delete()
            if (!resumed) return DownloadResult(name, 0L, ok = false, error = "checksum SHA-256 tidak cocok")
        }
    }
}
