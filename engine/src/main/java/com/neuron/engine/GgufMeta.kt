package com.neuron.engine

import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/**
 * Baca dan ubah metadata (key-value) berkas GGUF langsung di perangkat, tanpa server.
 *
 * Yang diubah hanya blok header. Data tensor (bobot) disalin utuh, byte demi byte, ke berkas baru.
 * Berkas asli tidak pernah ditimpa. Tidak ada dependensi Android supaya bisa dites sebagai JUnit biasa.
 *
 * Format (little-endian): "GGUF", versi u32 (2 atau 3), jumlah tensor u64, jumlah KV u64,
 * lalu KV (key string, tipe u32, nilai), lalu info tensor, lalu padding ke `general.alignment` (bawaan 32), lalu data tensor.
 * Offset di info tensor relatif terhadap awal data, jadi tidak berubah saat header berubah ukuran.
 */
class GgufException(message: String) : Exception(message)
class GgufCancelled : Exception("Dibatalkan")

enum class GgufType(val id: Int, val label: String, val size: Int) {
    UINT8(0, "uint8", 1), INT8(1, "int8", 1), UINT16(2, "uint16", 2), INT16(3, "int16", 2),
    UINT32(4, "uint32", 4), INT32(5, "int32", 4), FLOAT32(6, "float32", 4), BOOL(7, "bool", 1),
    STRING(8, "string", 0), ARRAY(9, "array", 0),
    UINT64(10, "uint64", 8), INT64(11, "int64", 8), FLOAT64(12, "float64", 8);

    companion object {
        fun of(id: Long): GgufType = values().firstOrNull { it.id.toLong() == id }
            ?: throw GgufException("Tipe metadata GGUF tidak dikenal: $id")

        fun byLabel(label: String): GgufType? = values().firstOrNull { it.label == label }
    }
}

/** Satu pasangan key-value. [start]..[end] = rentang byte aslinya di berkas sumber (untuk disalin tanpa diubah). */
data class GgufEntry(
    val key: String,
    val type: GgufType,
    val elemType: GgufType?,
    val arrayCount: Long,
    /** String, Long (semua bilangan bulat), Double, Boolean; null untuk array atau string > 4 MiB. */
    val value: Any?,
    val start: Long,
    val end: Long,
    /** Untuk array: posisi byte elemen pertama di berkas (setelah tipe elemen dan jumlah). -1 untuk bukan array. */
    val bodyStart: Long = -1L,
) {
    val editable: Boolean get() = type != GgufType.ARRAY && value != null
}

/** Tipe tensor ggml: nama, jumlah elemen per blok, dan byte per blok. Dipakai untuk menghitung ukuran tiap tensor. */
object GgmlTypes {
    class Info(val name: String, val block: Int, val bytes: Int)

    private val table: Map<Int, Info> = mapOf(
        0 to Info("F32", 1, 4), 1 to Info("F16", 1, 2),
        2 to Info("Q4_0", 32, 18), 3 to Info("Q4_1", 32, 20),
        6 to Info("Q5_0", 32, 22), 7 to Info("Q5_1", 32, 24),
        8 to Info("Q8_0", 32, 34), 9 to Info("Q8_1", 32, 36),
        10 to Info("Q2_K", 256, 84), 11 to Info("Q3_K", 256, 110), 12 to Info("Q4_K", 256, 144),
        13 to Info("Q5_K", 256, 176), 14 to Info("Q6_K", 256, 210), 15 to Info("Q8_K", 256, 292),
        16 to Info("IQ2_XXS", 256, 66), 17 to Info("IQ2_XS", 256, 74), 18 to Info("IQ3_XXS", 256, 98),
        19 to Info("IQ1_S", 256, 50), 20 to Info("IQ4_NL", 32, 18), 21 to Info("IQ3_S", 256, 110),
        22 to Info("IQ2_S", 256, 82), 23 to Info("IQ4_XS", 256, 136),
        24 to Info("I8", 1, 1), 25 to Info("I16", 1, 2), 26 to Info("I32", 1, 4), 27 to Info("I64", 1, 8),
        28 to Info("F64", 1, 8), 29 to Info("IQ1_M", 256, 56), 30 to Info("BF16", 1, 2),
    )

    fun info(id: Int): Info? = table[id]
    fun name(id: Int): String = table[id]?.name ?: "tipe#$id"

    /** Byte untuk tensor dengan dimensi [dims]; -1 bila tipe tidak dikenal, dimensi tidak valid, atau ne[0] bukan kelipatan blok. */
    fun bytes(id: Int, dims: List<Long>): Long {
        val t = table[id] ?: return -1L
        if (dims.isEmpty() || dims.any { it < 0 }) return -1L
        if (dims[0] % t.block != 0L) return -1L
        var elements = 1L
        for (d in dims) {
            elements = try { Math.multiplyExact(elements, d) } catch (_: ArithmeticException) { return -1L }
        }
        return try { Math.multiplyExact(elements / t.block, t.bytes.toLong()) } catch (_: ArithmeticException) { -1L }
    }

    private val fileTypes = mapOf(
        0L to "F32", 1L to "F16", 2L to "Q4_0", 3L to "Q4_1", 7L to "Q8_0", 8L to "Q5_0", 9L to "Q5_1",
        10L to "Q2_K", 11L to "Q3_K_S", 12L to "Q3_K_M", 13L to "Q3_K_L", 14L to "Q4_K_S", 15L to "Q4_K_M",
        16L to "Q5_K_S", 17L to "Q5_K_M", 18L to "Q6_K", 19L to "IQ2_XXS", 20L to "IQ2_XS", 21L to "Q2_K_S",
        22L to "IQ3_XS", 23L to "IQ3_XXS", 24L to "IQ1_S", 25L to "IQ4_NL", 26L to "IQ3_S", 27L to "IQ3_M",
        28L to "IQ2_S", 29L to "IQ2_M", 30L to "IQ4_XS", 31L to "IQ1_M", 32L to "BF16",
    )

    /** Nama kuantisasi dari nilai `general.file_type` (mis. 15 -> Q4_K_M); null bila tidak ada atau tidak dikenal. */
    fun fileTypeName(v: Long?): String? = v?.let { fileTypes[it] }
}

/** Satu entri info tensor. [offset] relatif terhadap awal data tensor. */
data class GgufTensor(val name: String, val dims: List<Long>, val typeId: Int, val offset: Long) {
    val typeName: String get() = GgmlTypes.name(typeId)

    /** Ukuran data tensor dalam byte; -1 bila tidak bisa dihitung. */
    val bytes: Long get() = GgmlTypes.bytes(typeId, dims)

    /** Jumlah elemen (parameter); -1 bila meluap. */
    val elements: Long
        get() {
            var n = 1L
            for (d in dims) n = try { Math.multiplyExact(n, d) } catch (_: ArithmeticException) { return -1L }
            return n
        }
}

data class GgufTypeStat(val type: String, val count: Int, val bytes: Long, val params: Long)

/** Hasil pembacaan total: seluruh tensor, ringkasan per tipe, dan daftar masalah integritas (kosong = utuh). */
data class GgufReport(
    val tensors: List<GgufTensor>,
    val totalParams: Long,
    val totalBytes: Long,
    val byType: List<GgufTypeStat>,
    val layers: Int,
    val issues: List<String>,
)

data class GgufFile(
    val version: Int,
    val tensorCount: Long,
    val entries: List<GgufEntry>,
    val alignment: Long,
    val tensorInfoStart: Long,
    val tensorInfoEnd: Long,
    val dataOffset: Long,
    val fileSize: Long,
) {
    fun entry(key: String): GgufEntry? = entries.firstOrNull { it.key == key }
    fun string(key: String): String? = entry(key)?.value as? String

    /** Jumlah token vocab (dari array tokenizer.ggml.tokens), atau -1 bila tidak ada. */
    val tokenCount: Long get() = entry("tokenizer.ggml.tokens")?.takeIf { it.type == GgufType.ARRAY }?.arrayCount ?: -1L
}

/** Perubahan yang diminta: ubah/tambah ([delete] = false) atau hapus ([delete] = true) satu key. */
data class GgufEdit(val key: String, val delete: Boolean = false, val type: GgufType? = null, val value: String = "")

object GgufReader {
    private const val MAX_STRING = 4L * 1024 * 1024
    private const val MAX_KEY = 512L
    private const val MAX_ARRAY_ITEM = 64L * 1024

    fun read(file: File): GgufFile = RandomAccessFile(file, "r").use { read(it) }

    fun read(raf: RandomAccessFile): GgufFile {
        val size = raf.length()
        val s = Src(raf, size)
        if (size < 24) throw GgufException("Berkas terlalu kecil untuk GGUF")
        val magic = s.bytes(4)
        if (!magic.contentEquals(byteArrayOf('G'.code.toByte(), 'G'.code.toByte(), 'U'.code.toByte(), 'F'.code.toByte())))
            throw GgufException("Bukan berkas GGUF (header tidak cocok)")
        val version = s.u32()
        if (version != 2L && version != 3L)
            throw GgufException("Versi GGUF $version tidak didukung editor (hanya v2/v3, little-endian)")
        val tensorCount = s.u64()
        val kvCount = s.u64()
        if (tensorCount < 0 || tensorCount > 10_000_000 || kvCount < 0 || kvCount > 1_000_000)
            throw GgufException("Jumlah tensor/metadata tidak masuk akal (berkas rusak?)")

        val entries = ArrayList<GgufEntry>(kvCount.toInt())
        val seen = HashSet<String>()
        for (i in 0 until kvCount) {
            val start = s.pos
            val key = String(s.bytes(s.checkedLen(s.u64(), MAX_KEY)), Charsets.UTF_8)
            if (!seen.add(key)) throw GgufException("Key metadata ganda: $key")
            val type = GgufType.of(s.u32())
            var elem: GgufType? = null
            var count = 0L
            var value: Any? = null
            var bodyStart = -1L
            if (type == GgufType.ARRAY) {
                elem = GgufType.of(s.u32())
                count = s.u64()
                if (count < 0) throw GgufException("Panjang array tidak valid pada $key")
                bodyStart = s.pos
                skipArrayBody(s, elem, count)
            } else if (type == GgufType.STRING) {
                val len = s.u64()
                if (len in 0..MAX_STRING) value = String(s.bytes(s.checkedLen(len, MAX_STRING)), Charsets.UTF_8)
                else s.skip(len)
            } else value = scalar(s, type)
            entries += GgufEntry(key, type, elem, count, value, start, s.pos, bodyStart)
        }

        val tensorInfoStart = s.pos
        for (t in 0 until tensorCount) {
            s.skipLen(s.u64(), MAX_KEY)                      // nama
            val dims = s.u32()
            if (dims < 1 || dims > 8) throw GgufException("Info tensor tidak valid (dimensi $dims)")
            s.skip(dims * 8)
            s.u32()                                          // tipe ggml
            s.u64()                                          // offset relatif data
        }
        val tensorInfoEnd = s.pos

        val alignEntry = entries.firstOrNull { it.key == "general.alignment" }
        val alignment = (alignEntry?.value as? Long) ?: 32L
        if (alignment <= 0 || (alignment and (alignment - 1)) != 0L) throw GgufException("general.alignment tidak valid: $alignment")
        val dataOffset = alignUp(tensorInfoEnd, alignment)
        if (dataOffset > size) throw GgufException("Berkas terpotong: data tensor tidak ada")
        return GgufFile(version.toInt(), tensorCount, entries, alignment, tensorInfoStart, tensorInfoEnd, dataOffset, size)
    }

    fun alignUp(n: Long, a: Long): Long = (n + a - 1) / a * a

    /** Teks tampilan nilai skalar GGUF (uint64 ditampilkan tanpa tanda, float32 tanpa noise double). */
    fun format(type: GgufType, v: Any?): String? = when (v) {
        null -> null
        is Boolean -> v.toString()
        is Double -> if (type == GgufType.FLOAT32) v.toFloat().toString() else v.toString()
        is Long -> if (type == GgufType.UINT64) java.lang.Long.toUnsignedString(v) else v.toString()
        else -> v.toString()
    }

    // ---------- Pembacaan total: tabel tensor, isi array, pemeriksaan integritas ----------

    fun readTensors(file: File, g: GgufFile): List<GgufTensor> = RandomAccessFile(file, "r").use { readTensors(it, g) }

    /** Baca seluruh info tensor (nama, bentuk, tipe, offset) dari [g]. Data bobot tidak dibaca. */
    fun readTensors(raf: RandomAccessFile, g: GgufFile): List<GgufTensor> {
        val s = Src(raf, raf.length())
        s.pos = g.tensorInfoStart
        val out = ArrayList<GgufTensor>(g.tensorCount.toInt())
        for (i in 0 until g.tensorCount) {
            val name = String(s.bytes(s.checkedLen(s.u64(), MAX_KEY)), Charsets.UTF_8)
            val n = s.u32()
            if (n < 1 || n > 8) throw GgufException("Info tensor $name tidak valid (dimensi $n)")
            val dims = List(n.toInt()) { s.u64() }
            if (dims.any { it < 0 }) throw GgufException("Info tensor $name tidak valid (dimensi negatif)")
            val type = s.u32().toInt()
            val offset = s.u64()
            out += GgufTensor(name, dims, type, offset)
        }
        if (s.pos != g.tensorInfoEnd) throw GgufException("Tabel tensor tidak konsisten dengan header")
        return out
    }

    /**
     * Periksa model secara total: setiap tensor harus bertipe dikenal, sejajar (alignment), tidak saling tumpang tindih,
     * dan seluruh datanya muat di dalam berkas. Masalah dikembalikan sebagai daftar kalimat, bukan exception,
     * supaya model yang cacat tetap bisa dilihat isinya.
     */
    fun analyze(g: GgufFile, tensors: List<GgufTensor>): GgufReport {
        val issues = ArrayList<String>()
        val dataLen = g.fileSize - g.dataOffset
        var totalParams = 0L
        var totalBytes = 0L
        val stats = LinkedHashMap<String, LongArray>() // [count, bytes, params]
        val names = HashSet<String>()
        val layerIds = HashSet<Int>()
        val layerRe = Regex("^blk\\.(\\d+)\\.")
        var unknown = 0; var misaligned = 0; var outside = 0; var dup = 0

        for (t in tensors) {
            if (!names.add(t.name)) dup++
            layerRe.find(t.name)?.groupValues?.get(1)?.toIntOrNull()?.let { layerIds += it }
            val bytes = t.bytes
            val params = t.elements
            val st = stats.getOrPut(t.typeName) { LongArray(3) }
            st[0]++
            if (params > 0) { totalParams += params; st[2] += params }
            if (bytes < 0) { unknown++; continue }
            totalBytes += bytes; st[1] += bytes
            if (t.offset % g.alignment != 0L) misaligned++
            if (t.offset < 0 || t.offset > dataLen || bytes > dataLen - t.offset) outside++
        }
        if (dup > 0) issues += "$dup nama tensor ganda"
        if (unknown > 0) issues += "$unknown tensor bertipe tidak dikenal atau berbentuk tidak valid; ukurannya tidak bisa diverifikasi"
        if (misaligned > 0) issues += "$misaligned tensor tidak sejajar dengan alignment ${g.alignment}"
        if (outside > 0) issues += "$outside tensor melewati akhir berkas: berkas terpotong atau unduhan belum lengkap"

        val known = tensors.filter { it.bytes >= 0 && it.offset >= 0 }.sortedBy { it.offset }
        var overlap = 0
        for (i in 1 until known.size) if (known[i].offset < known[i - 1].offset + known[i - 1].bytes) overlap++
        if (overlap > 0) issues += "$overlap tensor saling tumpang tindih di data"

        val arch = g.string("general.architecture")
        if (arch == null) issues += "general.architecture tidak ada"
        val blocks = arch?.let { g.entry("$it.block_count")?.value as? Long }
        if (blocks != null && layerIds.isNotEmpty() && layerIds.size.toLong() != blocks)
            issues += "Header menyebut $blocks blok, tetapi tensor hanya untuk ${layerIds.size} blok"
        if (tensors.isEmpty()) issues += "Berkas tidak berisi tensor"

        val byType = stats.entries.map { GgufTypeStat(it.key, it.value[0].toInt(), it.value[1], it.value[2]) }.sortedByDescending { it.bytes }
        return GgufReport(tensors, totalParams, totalBytes, byType, layerIds.size, issues)
    }

    /**
     * Baca sebagian isi array [entry] (mis. daftar token): [limit] elemen mulai dari indeks [offset].
     * Elemen ditampilkan sebagai teks. Array bersarang tidak didukung.
     */
    fun readArray(file: File, entry: GgufEntry, offset: Long, limit: Int): List<String> =
        RandomAccessFile(file, "r").use { readArray(it, entry, offset, limit) }

    fun readArray(raf: RandomAccessFile, entry: GgufEntry, offset: Long, limit: Int): List<String> {
        if (entry.type != GgufType.ARRAY || entry.bodyStart < 0) throw GgufException("${entry.key} bukan array")
        val elem = entry.elemType ?: throw GgufException("${entry.key}: tipe elemen array tidak diketahui")
        if (elem == GgufType.ARRAY) throw GgufException("Array bersarang belum bisa ditampilkan")
        if (offset < 0 || limit < 1) throw GgufException("Rentang array tidak valid")
        val n = minOf(limit.toLong(), entry.arrayCount - offset)
        if (n <= 0) return emptyList()
        val s = Src(raf, raf.length())
        s.pos = entry.bodyStart
        val out = ArrayList<String>(n.toInt())
        if (elem == GgufType.STRING) {
            for (i in 0 until offset) s.skipLen(s.u64(), Long.MAX_VALUE)
            for (i in 0 until n) {
                val len = s.u64()
                if (len < 0 || len > s.remaining()) throw GgufException("Panjang string array tidak valid; berkas rusak?")
                if (len > MAX_ARRAY_ITEM) { s.skipLen(len, Long.MAX_VALUE); out += "(string $len byte)" }
                else out += String(s.bytes(len.toInt()), Charsets.UTF_8)
            }
        } else {
            s.pos = entry.bodyStart + offset * elem.size
            for (i in 0 until n) out += format(elem, scalar(s, elem)) ?: ""
        }
        return out
    }

    private fun scalar(s: Src, t: GgufType): Any = when (t) {
        GgufType.UINT8 -> s.byte().toLong()
        GgufType.INT8 -> s.byte().toByte().toLong()
        GgufType.UINT16 -> s.u16().toLong()
        GgufType.INT16 -> s.u16().toShort().toLong()
        GgufType.UINT32 -> s.u32()
        GgufType.INT32 -> s.u32().toInt().toLong()
        GgufType.FLOAT32 -> java.lang.Float.intBitsToFloat(s.u32().toInt()).toDouble()
        GgufType.BOOL -> s.byte() != 0
        GgufType.UINT64, GgufType.INT64 -> s.u64()
        GgufType.FLOAT64 -> java.lang.Double.longBitsToDouble(s.u64())
        else -> throw GgufException("Tipe ${t.label} bukan skalar")
    }

    private fun skipArrayBody(s: Src, elem: GgufType, count: Long) {
        when (elem) {
            GgufType.STRING -> for (i in 0 until count) s.skipLen(s.u64(), Long.MAX_VALUE)
            GgufType.ARRAY -> for (i in 0 until count) {
                val inner = GgufType.of(s.u32()); val n = s.u64()
                if (n < 0) throw GgufException("Panjang array bersarang tidak valid")
                skipArrayBody(s, inner, n)
            }
            else -> {
                if (count > Long.MAX_VALUE / 8) throw GgufException("Panjang array tidak masuk akal")
                s.skip(count * elem.size)
            }
        }
    }

    /** Pembaca berpenyangga di atas RandomAccessFile dengan penghitung posisi. */
    private class Src(private val raf: RandomAccessFile, private val size: Long) {
        private val buf = ByteArray(1 shl 16)
        private var bufStart = 0L
        private var bufLen = 0
        var pos = 0L

        private fun fill() {
            raf.seek(pos)
            val n = raf.read(buf, 0, buf.size)
            if (n <= 0) throw GgufException("Berkas GGUF terpotong di byte $pos")
            bufStart = pos; bufLen = n
        }

        fun byte(): Int {
            if (pos < bufStart || pos >= bufStart + bufLen) fill()
            val v = buf[(pos - bufStart).toInt()].toInt() and 0xFF
            pos++
            return v
        }

        fun bytes(n: Int): ByteArray {
            val out = ByteArray(n)
            var off = 0
            while (off < n) {
                if (pos < bufStart || pos >= bufStart + bufLen) fill()
                val take = minOf((bufStart + bufLen - pos).toInt(), n - off)
                System.arraycopy(buf, (pos - bufStart).toInt(), out, off, take)
                pos += take; off += take
            }
            return out
        }

        fun remaining(): Long = size - pos

        fun skip(n: Long) {
            if (n < 0 || pos + n > size || pos + n < pos) throw GgufException("Berkas GGUF terpotong atau rusak (lompat $n byte)")
            pos += n
        }

        fun u16(): Int = byte() or (byte() shl 8)
        fun u32(): Long = (u16().toLong()) or (u16().toLong() shl 16)
        fun u64(): Long = u32() or (u32() shl 32)

        /** Panjang dari berkas harus masuk akal sebelum dipakai alokasi atau lompat. */
        fun checkedLen(len: Long, max: Long): Int {
            if (len < 0 || len > max || len > size - pos || len > Int.MAX_VALUE)
                throw GgufException("Panjang data tidak valid ($len); berkas rusak?")
            return len.toInt()
        }

        fun skipLen(len: Long, max: Long) {
            if (len < 0 || len > max || len > size - pos) throw GgufException("Panjang data tidak valid ($len); berkas rusak?")
            pos += len
        }
    }
}

object GgufEditor {
    private const val CHUNK = 8L * 1024 * 1024
    private val KEY_RE = Regex("^[A-Za-z0-9._-]{1,255}$")

    /** Key yang mengubah bentuk tensor atau cara membaca berkas: mengubahnya membuat model gagal dimuat atau rusak. */
    private val PROTECTED_EXACT = setOf(
        "general.architecture", "general.alignment", "general.file_type", "general.quantization_version",
    )
    private val PROTECTED_SUFFIX = listOf(
        ".block_count", ".embedding_length", ".feed_forward_length", ".attention.head_count", ".attention.head_count_kv",
        ".vocab_size", ".expert_count", ".expert_used_count",
    )

    /** Alasan key tidak boleh diubah/dihapus, atau null bila boleh. */
    fun protectionReason(key: String, entry: GgufEntry? = null): String? = when {
        key in PROTECTED_EXACT -> "Key ini menentukan cara model dibaca; mengubahnya membuat model rusak."
        PROTECTED_SUFFIX.any { key.endsWith(it) } -> "Key ini menentukan bentuk tensor; mengubahnya membuat model gagal dimuat."
        entry?.type == GgufType.ARRAY -> "Array (mis. daftar token) hanya bisa dibaca di editor ini."
        else -> null
    }

    private val ADD_TYPES = setOf(
        GgufType.STRING, GgufType.BOOL, GgufType.UINT32, GgufType.INT32, GgufType.UINT64, GgufType.INT64,
        GgufType.FLOAT32, GgufType.FLOAT64,
    )

    /** Ubah teks bentuk-bebas menjadi byte nilai GGUF bertipe [t]. Melempar [GgufException] bila tidak valid. */
    fun encodeValue(t: GgufType, text: String): ByteArray {
        fun le(size: Int, fill: (ByteBuffer) -> Unit) = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN).also(fill).array()
        fun int(min: Long, max: Long): Long {
            val v = text.trim().toLongOrNull() ?: throw GgufException("'$text' bukan bilangan bulat untuk ${t.label}")
            if (v < min || v > max) throw GgufException("Nilai $v di luar rentang ${t.label} ($min..$max)")
            return v
        }
        return when (t) {
            GgufType.STRING -> {
                val b = text.toByteArray(Charsets.UTF_8)
                if (b.size > 1 shl 20) throw GgufException("String terlalu panjang (maksimal 1 MiB)")
                le(8 + b.size) { it.putLong(b.size.toLong()); it.put(b) }
            }
            GgufType.BOOL -> when (text.trim().lowercase()) {
                "true", "1", "ya" -> byteArrayOf(1)
                "false", "0", "tidak" -> byteArrayOf(0)
                else -> throw GgufException("Nilai bool harus true atau false")
            }
            GgufType.UINT8 -> byteArrayOf(int(0, 255).toByte())
            GgufType.INT8 -> byteArrayOf(int(-128, 127).toByte())
            GgufType.UINT16 -> le(2) { it.putShort(int(0, 65535).toShort()) }
            GgufType.INT16 -> le(2) { it.putShort(int(-32768, 32767).toShort()) }
            GgufType.UINT32 -> le(4) { it.putInt(int(0, 4294967295L).toInt()) }
            GgufType.INT32 -> le(4) { it.putInt(int(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()) }
            GgufType.UINT64 -> {
                val t64 = text.trim()
                val parsed = if (t64.matches(Regex("^[0-9]{1,20}$"))) runCatching { java.lang.Long.parseUnsignedLong(t64) }.getOrNull() else null
                val v: Long = parsed ?: throw GgufException("'$text' bukan bilangan bulat tak bertanda (0..18446744073709551615)")
                le(8) { it.putLong(v) }
            }
            GgufType.INT64 -> le(8) { it.putLong(int(Long.MIN_VALUE, Long.MAX_VALUE)) }
            GgufType.FLOAT32 -> le(4) {
                val v = text.trim().toFloatOrNull()?.takeIf { f -> f.isFinite() } ?: throw GgufException("'$text' bukan bilangan desimal yang valid")
                it.putFloat(v)
            }
            GgufType.FLOAT64 -> le(8) {
                val v = text.trim().toDoubleOrNull()?.takeIf { d -> d.isFinite() } ?: throw GgufException("'$text' bukan bilangan desimal yang valid")
                it.putDouble(v)
            }
            GgufType.ARRAY -> throw GgufException("Array tidak bisa diedit")
        }
    }

    private fun encodeKey(key: String): ByteArray {
        val b = key.toByteArray(Charsets.UTF_8)
        return ByteBuffer.allocate(8 + b.size).order(ByteOrder.LITTLE_ENDIAN).putLong(b.size.toLong()).put(b).array()
    }

    private fun u32(v: Int): ByteArray = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array()

    /** Satu bagian header baru: byte baru, atau rentang berkas sumber yang disalin apa adanya. */
    private sealed class Seg { class Bytes(val b: ByteArray) : Seg(); class Raw(val start: Long, val end: Long) : Seg() }

    /** Periksa semua perubahan terhadap [src]. Mengembalikan daftar segmen header baru + jumlah KV baru. */
    private fun plan(src: GgufFile, edits: List<GgufEdit>): Pair<List<Seg>, Long> {
        if (edits.isEmpty()) throw GgufException("Tidak ada perubahan untuk disimpan")
        val byKey = HashMap<String, GgufEdit>()
        for (e in edits) {
            if (!KEY_RE.matches(e.key)) throw GgufException("Nama key tidak valid: '${e.key}' (huruf, angka, titik, garis bawah, minus)")
            if (byKey.put(e.key, e) != null) throw GgufException("Key diubah dua kali: ${e.key}")
        }
        val segs = ArrayList<Seg>()
        var kvCount = 0L
        val used = HashSet<String>()
        for (entry in src.entries) {
            val e = byKey[entry.key]
            if (e == null) { segs += Seg.Raw(entry.start, entry.end); kvCount++; continue }
            used += entry.key
            protectionReason(entry.key, entry)?.let { throw GgufException("${entry.key}: $it") }
            if (e.delete) continue
            if (!entry.editable) throw GgufException("${entry.key}: nilai ini tidak bisa diedit")
            if (e.type != null && e.type != entry.type) throw GgufException("${entry.key}: tipe ${entry.type.label} tidak boleh diganti")
            segs += newKv(src, entry.key, entry.type, e.value)
            kvCount++
        }
        for (e in edits) {
            if (e.key in used) continue
            if (e.delete) throw GgufException("${e.key}: key tidak ada, tidak bisa dihapus")
            protectionReason(e.key)?.let { throw GgufException("${e.key}: $it") }
            val t = e.type ?: throw GgufException("${e.key}: tipe wajib diisi untuk key baru")
            if (t !in ADD_TYPES) throw GgufException("${e.key}: tipe ${t.label} tidak bisa ditambahkan")
            segs += newKv(src, e.key, t, e.value)
            kvCount++
        }
        return segs to kvCount
    }

    private fun newKv(src: GgufFile, key: String, type: GgufType, text: String): Seg {
        val value = encodeValue(type, text)
        if (key == "tokenizer.chat_template" && text.isBlank())
            throw GgufException("Template chat tidak boleh kosong; hapus key-nya bila ingin memakai bawaan engine")
        val idMatch = Regex("^tokenizer\\.ggml\\.[a-z_]+_token_id$").matches(key)
        if (idMatch) {
            val id = text.trim().toLongOrNull() ?: throw GgufException("$key harus berupa angka ID token")
            val n = src.tokenCount
            if (id < 0 || (n >= 0 && id >= n)) throw GgufException("$key: ID $id di luar vocab (0..${n - 1})")
        }
        val out = encodeKey(key) + u32(type.id) + value
        return Seg.Bytes(out)
    }

    /**
     * Tulis salinan [src] dengan metadata berubah ke [dst]. [src] tidak disentuh.
     * Ditulis ke "<dst>.part", diperiksa ulang, lalu di-rename; bila gagal, berkas sementara dihapus.
     * [onProgress] menerima (byte tertulis, total byte). [cancelled] dicek tiap potongan 8 MiB.
     */
    fun rewrite(
        src: File, dst: File, edits: List<GgufEdit>,
        onProgress: (Long, Long) -> Unit = { _, _ -> },
        cancelled: () -> Boolean = { false },
    ): GgufFile {
        require(src.canonicalFile != dst.canonicalFile) { "Berkas hasil harus berbeda dari berkas asli" }
        if (dst.exists()) throw GgufException("Berkas hasil sudah ada: ${dst.name}")
        val info = GgufReader.read(src)
        val (segs, kvCount) = plan(info, edits)

        val head = java.io.ByteArrayOutputStream().apply {
            write(byteArrayOf('G'.code.toByte(), 'G'.code.toByte(), 'U'.code.toByte(), 'F'.code.toByte()))
            write(u32(info.version))
            write(ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN).putLong(info.tensorCount).putLong(kvCount).array())
        }.toByteArray()
        var kvLen = 0L
        for (s in segs) kvLen += when (s) { is Seg.Bytes -> s.b.size.toLong(); is Seg.Raw -> s.end - s.start }
        val tensorInfoLen = info.tensorInfoEnd - info.tensorInfoStart
        val newInfoEnd = head.size + kvLen + tensorInfoLen
        val newDataOffset = GgufReader.alignUp(newInfoEnd, info.alignment)
        val dataLen = info.fileSize - info.dataOffset
        val expected = newDataOffset + dataLen

        val parent = dst.absoluteFile.parentFile ?: throw GgufException("Folder tujuan tidak valid")
        if (parent.usableSpace < expected + 64L * 1024 * 1024)
            throw GgufException("Ruang penyimpanan kurang: perlu sekitar ${(expected + 64L * 1024 * 1024) / (1024 * 1024)} MB bebas")

        val tmp = File(dst.path + ".part")
        tmp.delete()
        var written = 0L
        try {
            RandomAccessFile(src, "r").use { raf ->
                FileOutputStream(tmp).use { fos ->
                    val from = raf.channel; val to = fos.channel
                    fun put(b: ByteArray) { fos.write(b); written += b.size; onProgress(written, expected) }
                    fun copy(start: Long, end: Long) = copyRange(from, start, end, to, cancelled) { written += it; onProgress(written, expected) }
                    put(head)
                    for (s in segs) when (s) { is Seg.Bytes -> put(s.b); is Seg.Raw -> copy(s.start, s.end) }
                    copy(info.tensorInfoStart, info.tensorInfoEnd)
                    put(ByteArray((newDataOffset - newInfoEnd).toInt()))
                    copy(info.dataOffset, info.fileSize)
                    fos.flush(); to.force(true)
                }
            }
            check(tmp.length() == expected) { "Ukuran hasil ${tmp.length()} B, seharusnya $expected B" }

            // Pemeriksaan ulang: header hasil terbaca, jumlah tensor sama, dan data tensor identik di awal dan akhir.
            val out = GgufReader.read(tmp)
            check(out.tensorCount == info.tensorCount && out.entries.size.toLong() == kvCount) { "Header hasil tidak cocok dengan rencana" }
            check(out.dataOffset == newDataOffset) { "Offset data hasil tidak cocok" }
            spotCheck(src, info.dataOffset, tmp, out.dataOffset, dataLen)
            if (!tmp.renameTo(dst)) throw GgufException("Gagal mengganti nama berkas hasil")
            return GgufReader.read(dst)
        } catch (t: Throwable) {
            tmp.delete()
            throw if (t is IllegalStateException) GgufException("Verifikasi hasil gagal: ${t.message}") else t
        }
    }

    private fun copyRange(from: FileChannel, start: Long, end: Long, to: FileChannel, cancelled: () -> Boolean, onBytes: (Long) -> Unit) {
        var pos = start
        while (pos < end) {
            if (cancelled()) throw GgufCancelled()
            val n = from.transferTo(pos, minOf(CHUNK, end - pos), to)
            if (n <= 0) throw GgufException("Gagal menyalin data model (disk penuh atau berkas terpotong)")
            pos += n
            onBytes(n)
        }
    }

    /** Bandingkan 64 KiB pertama dan terakhir data tensor di sumber dan hasil. */
    private fun spotCheck(a: File, aOff: Long, b: File, bOff: Long, len: Long) {
        if (len <= 0) return
        val n = minOf(len, 65536L).toInt()
        RandomAccessFile(a, "r").use { fa -> RandomAccessFile(b, "r").use { fb ->
            for (rel in listOf(0L, len - n)) {
                val x = ByteArray(n); val y = ByteArray(n)
                fa.seek(aOff + rel); fa.readFully(x); fb.seek(bOff + rel); fb.readFully(y)
                check(x.contentEquals(y)) { "Data tensor berbeda dari sumber (posisi $rel)" }
            }
        } }
    }
}
