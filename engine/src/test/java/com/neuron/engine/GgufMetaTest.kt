package com.neuron.engine

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files

/** GGUF sintetis kecil dibuat di tes supaya tidak butuh berkas model nyata. */
class GgufMetaTest {
    private val dir: File = Files.createTempDirectory("gguf-test").toFile()

    @After fun cleanup() { dir.deleteRecursively() }

    private fun le(n: Int) = ByteBuffer.allocate(n).order(ByteOrder.LITTLE_ENDIAN)
    private fun str(s: String): ByteArray { val b = s.toByteArray(); return le(8 + b.size).putLong(b.size.toLong()).put(b).array() }
    private fun u32(v: Long) = le(4).putInt(v.toInt()).array()
    private fun kvStr(k: String, v: String) = str(k) + u32(8) + str(v)
    private fun kvU32(k: String, v: Long) = str(k) + u32(4) + u32(v)
    private fun kvTokens(n: Int): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(str("tokenizer.ggml.tokens")); out.write(u32(9)); out.write(u32(8)); out.write(le(8).putLong(n.toLong()).array())
        for (i in 0 until n) out.write(str("tok$i"))
        return out.toByteArray()
    }

    /** Mengembalikan (berkas, data tensor asli). */
    private fun kvU32Array(k: String, vals: List<Long>): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(str(k)); out.write(u32(9)); out.write(u32(4)); out.write(le(8).putLong(vals.size.toLong()).array())
        vals.forEach { out.write(u32(it)) }
        return out.toByteArray()
    }

    private fun build(align: Int = 32, alignKv: Boolean = true, name: String = "m.gguf", extra: List<ByteArray> = emptyList()): Pair<File, ByteArray> {
        val kvs = mutableListOf(
            kvStr("general.architecture", "llama"),
            kvStr("general.name", "Tiny"),
            kvStr("tokenizer.chat_template", "{{ messages }}".repeat(10)),
            kvTokens(50),
            kvU32("tokenizer.ggml.eos_token_id", 2),
            kvU32("llama.context_length", 2048),
            kvU32("llama.block_count", 2),
        )
        if (alignKv) kvs.add(2, kvU32("general.alignment", align.toLong()))
        kvs.addAll(extra)
        val tensors = 3
        val info = ByteArrayOutputStream(); val data = ByteArrayOutputStream(); var off = 0L
        for (i in 0 until tensors) {
            info.write(str("blk.$i.w")); info.write(u32(2)); info.write(le(16).putLong(10).putLong(10L * (i + 1)).array())
            info.write(u32(0)); info.write(le(8).putLong(off).array())
            val n = 400 * (i + 1); val sz = (n + align - 1) / align * align
            val chunk = ByteArray(sz) { ((it * 31 + i * 7) and 0xFF).toByte() }
            data.write(chunk); off += sz
        }
        val head = ByteArrayOutputStream()
        head.write("GGUF".toByteArray()); head.write(u32(3)); head.write(le(16).putLong(tensors.toLong()).putLong(kvs.size.toLong()).array())
        kvs.forEach { head.write(it) }
        head.write(info.toByteArray())
        val pad = (align - head.size() % align) % align
        head.write(ByteArray(pad))
        val f = File(dir, name)
        f.writeBytes(head.toByteArray() + data.toByteArray())
        return f to data.toByteArray()
    }

    private fun dataOf(f: File): ByteArray { val g = GgufReader.read(f); return f.readBytes().copyOfRange(g.dataOffset.toInt(), f.length().toInt()) }

    @Test fun readsEntriesAndKeepsArraysOpaque() {
        val (f, _) = build()
        val g = GgufReader.read(f)
        assertEquals(3, g.version)
        assertEquals(3L, g.tensorCount)
        assertEquals("Tiny", g.string("general.name"))
        assertEquals(2048L, g.entry("llama.context_length")?.value)
        assertEquals(50L, g.tokenCount)
        assertNull(g.entry("tokenizer.ggml.tokens")?.value)
        assertFalse(g.entry("tokenizer.ggml.tokens")!!.editable)
    }

    @Test fun rewriteChangesTemplateAndKeepsTensorDataIdentical() {
        val (f, data) = build()
        val out = File(dir, "out.gguf")
        val g2 = GgufEditor.rewrite(f, out, listOf(GgufEdit("tokenizer.chat_template", value = "chatml")))
        assertEquals("chatml", g2.string("tokenizer.chat_template"))
        assertArrayEquals(data, dataOf(out))
        assertEquals(0L, g2.dataOffset % g2.alignment)
        assertEquals(g2.tokenCount, 50L)
        assertTrue("berkas asli tidak boleh berubah", GgufReader.read(f).string("tokenizer.chat_template")!!.startsWith("{{"))
        assertFalse(File(out.path + ".part").exists())
    }

    @Test fun longerHeaderShiftsDataOffsetButNotData() {
        val (f, data) = build(align = 64)
        val out = File(dir, "big.gguf")
        val g2 = GgufEditor.rewrite(f, out, listOf(GgufEdit("tokenizer.chat_template", value = "x".repeat(5000))))
        assertTrue(g2.dataOffset > GgufReader.read(f).dataOffset)
        assertEquals(0L, g2.dataOffset % 64)
        assertArrayEquals(data, dataOf(out))
    }

    @Test fun addAndDeleteKeys() {
        val (f, data) = build()
        val out = File(dir, "ad.gguf")
        val g2 = GgufEditor.rewrite(f, out, listOf(
            GgufEdit("general.description", type = GgufType.STRING, value = "uji"),
            GgufEdit("my.flag", type = GgufType.BOOL, value = "true"),
            GgufEdit("tokenizer.chat_template", delete = true),
        ))
        assertEquals("uji", g2.string("general.description"))
        assertEquals(true, g2.entry("my.flag")?.value)
        assertNull(g2.entry("tokenizer.chat_template"))
        assertArrayEquals(data, dataOf(out))
    }

    @Test fun worksWithoutAlignmentKeyUsingDefault32() {
        val (f, data) = build(alignKv = false)
        val out = File(dir, "na.gguf")
        val g2 = GgufEditor.rewrite(f, out, listOf(GgufEdit("general.name", value = "Nama Baru")))
        assertEquals(32L, g2.alignment)
        assertArrayEquals(data, dataOf(out))
    }

    @Test fun protectedKeysAreRejected() {
        val (f, _) = build()
        for (key in listOf("general.architecture", "general.alignment", "llama.block_count", "tokenizer.ggml.tokens")) {
            try { GgufEditor.rewrite(f, File(dir, "p-$key.gguf"), listOf(GgufEdit(key, value = "1"))); fail("harus ditolak: $key") }
            catch (e: GgufException) { assertTrue(e.message!!.startsWith(key)) }
        }
        try { GgufEditor.rewrite(f, File(dir, "d.gguf"), listOf(GgufEdit("llama.block_count", delete = true))); fail() } catch (_: GgufException) {}
    }

    @Test fun tokenIdMustStayInsideVocab() {
        val (f, _) = build()
        try { GgufEditor.rewrite(f, File(dir, "t.gguf"), listOf(GgufEdit("tokenizer.ggml.eos_token_id", value = "50"))); fail() } catch (_: GgufException) {}
        val g = GgufEditor.rewrite(f, File(dir, "t2.gguf"), listOf(GgufEdit("tokenizer.ggml.eos_token_id", value = "49")))
        assertEquals(49L, g.entry("tokenizer.ggml.eos_token_id")?.value)
    }

    @Test fun invalidValuesAndTypes() {
        val (f, _) = build()
        fun bad(e: GgufEdit) { try { GgufEditor.rewrite(f, File(dir, "x${e.key}${System.nanoTime()}.gguf"), listOf(e)); fail("harus ditolak: $e") } catch (_: GgufException) {} }
        bad(GgufEdit("llama.context_length", value = "abc"))
        bad(GgufEdit("llama.context_length", value = "-1"))
        bad(GgufEdit("llama.context_length", value = "4294967296"))
        bad(GgufEdit("llama.context_length", type = GgufType.STRING, value = "4096"))   // tipe tidak boleh diganti
        bad(GgufEdit("tokenizer.chat_template", value = "   "))
        bad(GgufEdit("baru", value = "1"))                                              // key baru tanpa tipe
        bad(GgufEdit("key spasi", type = GgufType.STRING, value = "x"))
        bad(GgufEdit("tidak.ada", delete = true))
        bad(GgufEdit("a", type = GgufType.FLOAT32, value = "NaN"))
    }

    @Test fun refusesToOverwriteAndKeepsSourceUntouched() {
        val (f, _) = build()
        val before = f.readBytes()
        val out = File(dir, "exists.gguf"); out.writeText("x")
        try { GgufEditor.rewrite(f, out, listOf(GgufEdit("general.name", value = "B"))); fail() } catch (_: GgufException) {}
        assertArrayEquals(before, f.readBytes())
    }

    @Test fun cancellationLeavesNoPartialFile() {
        val (f, _) = build()
        val out = File(dir, "c.gguf")
        try { GgufEditor.rewrite(f, out, listOf(GgufEdit("general.name", value = "C")), cancelled = { true }); fail() } catch (_: GgufCancelled) {}
        assertFalse(out.exists()); assertFalse(File(out.path + ".part").exists())
    }

    @Test fun rejectsNonGgufAndTruncatedFiles() {
        val junk = File(dir, "junk.gguf"); junk.writeBytes(ByteArray(100) { 1 })
        try { GgufReader.read(junk); fail() } catch (_: GgufException) {}
        val (f, _) = build()
        val cut = File(dir, "cut.gguf"); cut.writeBytes(f.readBytes().copyOf(120))
        try { GgufReader.read(cut); fail() } catch (_: GgufException) {}
        assertNotNull(GgufReader.read(f))
    }

    @Test fun encodeValueRanges() {
        assertEquals(1, GgufEditor.encodeValue(GgufType.BOOL, "TRUE").size)
        assertEquals(8, GgufEditor.encodeValue(GgufType.UINT64, "18446744073709551615").size)
        try { GgufEditor.encodeValue(GgufType.UINT64, "18446744073709551616"); fail() } catch (_: GgufException) {}
        assertEquals(255.toByte(), GgufEditor.encodeValue(GgufType.UINT8, "255")[0])
        try { GgufEditor.encodeValue(GgufType.UINT8, "256"); fail() } catch (_: GgufException) {}
    }

    // ---------- Pembacaan total: tensor, array, integritas ----------

    @Test fun readsFullTensorTable() {
        val (f, _) = build()
        val g = GgufReader.read(f)
        val t = GgufReader.readTensors(f, g)
        assertEquals(3, t.size)
        assertEquals("blk.0.w", t[0].name)
        assertEquals(listOf(10L, 10L), t[0].dims)
        assertEquals("F32", t[0].typeName)
        assertEquals(400L, t[0].bytes)
        assertEquals(800L, t[1].bytes)
        assertEquals(1200L, t[2].bytes)
        assertEquals(100L + 200L + 300L, t.sumOf { it.elements })
        assertEquals(0L, t[0].offset)
    }

    @Test fun analyzeReportsTotalsAndFindsBlockMismatch() {
        val (f, _) = build()
        val g = GgufReader.read(f)
        val r = GgufReader.analyze(g, GgufReader.readTensors(f, g))
        assertEquals(600L, r.totalParams)
        assertEquals(2400L, r.totalBytes)
        assertEquals(1, r.byType.size)
        assertEquals(3, r.layers)
        // helper memuat block_count=2 tetapi 3 blok tensor: harus tertangkap, dan hanya itu
        assertEquals(1, r.issues.size)
        assertTrue(r.issues[0], r.issues[0].contains("blok"))
    }

    @Test fun analyzeDetectsTruncatedDownload() {
        val (f, _) = build()
        val cut = File(dir, "cut-data.gguf")
        cut.writeBytes(f.readBytes().copyOf(f.length().toInt() - 500))
        val g = GgufReader.read(cut)
        val r = GgufReader.analyze(g, GgufReader.readTensors(cut, g))
        assertTrue(r.issues.toString(), r.issues.any { it.contains("melewati akhir berkas") })
    }

    @Test fun readsStringArrayInPages() {
        val (f, _) = build()
        val g = GgufReader.read(f)
        val e = g.entry("tokenizer.ggml.tokens")!!
        assertEquals(listOf("tok0", "tok1", "tok2"), GgufReader.readArray(f, e, 0, 3))
        assertEquals(listOf("tok10", "tok11", "tok12", "tok13", "tok14"), GgufReader.readArray(f, e, 10, 5))
        assertEquals(listOf("tok48", "tok49"), GgufReader.readArray(f, e, 48, 100))
        assertTrue(GgufReader.readArray(f, e, 50, 10).isEmpty())
        try { GgufReader.readArray(f, g.entry("general.name")!!, 0, 1); fail() } catch (_: GgufException) {}
    }

    @Test fun readsScalarArrayAndStaysReadableAfterEdit() {
        val (f, data) = build(extra = listOf(kvU32Array("tokenizer.ggml.token_type", listOf(1, 3, 3, 4, 1, 1))))
        val g = GgufReader.read(f)
        val e = g.entry("tokenizer.ggml.token_type")!!
        assertEquals(listOf("3", "3", "4"), GgufReader.readArray(f, e, 1, 3))
        // array tetap utuh dan terbaca setelah header diubah (offset bodyStart bergeser)
        val out = File(dir, "arr.gguf")
        val g2 = GgufEditor.rewrite(f, out, listOf(GgufEdit("general.name", value = "Nama yang jauh lebih panjang dari sebelumnya")))
        assertEquals(listOf("1", "3", "3", "4", "1", "1"), GgufReader.readArray(out, g2.entry("tokenizer.ggml.token_type")!!, 0, 10))
        assertEquals(50L, g2.tokenCount)
        assertArrayEquals(data, dataOf(out))
    }

    @Test fun fullReadWorksOnEditedCopy() {
        val (f, _) = build()
        val out = File(dir, "full.gguf")
        val g2 = GgufEditor.rewrite(f, out, listOf(GgufEdit("tokenizer.chat_template", value = "chatml")))
        val t = GgufReader.readTensors(out, g2)
        assertEquals(listOf("blk.0.w", "blk.1.w", "blk.2.w"), t.map { it.name })
        assertEquals(2400L, GgufReader.analyze(g2, t).totalBytes)
    }

    @Test fun ggmlSizesAndFileTypeNames() {
        assertEquals(2L * 144, GgmlTypes.bytes(12, listOf(256L, 2L)))      // Q4_K: 144 B per blok 256
        assertEquals(34L, GgmlTypes.bytes(8, listOf(32L)))                 // Q8_0
        assertEquals(-1L, GgmlTypes.bytes(12, listOf(100L, 2L)))           // ne[0] bukan kelipatan blok
        assertEquals(-1L, GgmlTypes.bytes(9999, listOf(1L)))               // tipe tidak dikenal
        assertEquals(-1L, GgmlTypes.bytes(0, listOf(Long.MAX_VALUE, 4L)))  // meluap
        assertEquals("Q4_K_M", GgmlTypes.fileTypeName(15))
        assertNull(GgmlTypes.fileTypeName(null))
        assertNull(GgmlTypes.fileTypeName(9999))
    }
}
