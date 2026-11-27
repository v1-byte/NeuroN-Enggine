package com.neuron.hf

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Unduhan model tidak boleh pernah meninggalkan berkas bernama akhir yang setengah jadi. */
class HfFilesTest {
    private val dir: File = Files.createTempDirectory("hf-files").toFile()
    private val full = ByteArray(5000) { (it * 7 + 3).toByte() }
    private val sha = HfFiles.sha256(File(dir, "ref").also { it.writeBytes(full) })
    private val dest = File(dir, "owner__repo/model.gguf")

    @After fun cleanup() { dir.deleteRecursively() }

    /** Server palsu: mengisi/melanjutkan [part] dengan [content] mulai dari byte yang sudah ada (seperti Range). */
    private fun serve(content: ByteArray, stopAt: Int = content.size): suspend (File) -> Unit = { part ->
        part.parentFile?.mkdirs()
        val start = if (part.isFile) part.length().toInt() else 0
        val upTo = minOf(stopAt, content.size)
        if (start < upTo) part.appendBytes(content.copyOfRange(start, upTo))
        if (upTo < content.size) throw java.io.IOException("jaringan putus")
    }

    @Test fun finalNameAppearsOnlyAfterVerifiedComplete() = runBlocking {
        val r = HfFiles.fetchVerified("model.gguf", dest, sha, serve(full))
        assertTrue(r.ok); assertTrue(r.verified)
        assertEquals(full.size.toLong(), r.bytes)
        assertArrayEquals(full, dest.readBytes())
        assertFalse(HfFiles.partOf(dest).exists())
    }

    @Test fun interruptedDownloadLeavesOnlyPartAndResumes() = runBlocking {
        try { HfFiles.fetchVerified("model.gguf", dest, sha, serve(full, stopAt = 2000)); fail() } catch (_: java.io.IOException) {}
        assertFalse("model setengah jadi tidak boleh bernama akhir", dest.exists())
        assertEquals(2000L, HfFiles.partOf(dest).length())
        val r = HfFiles.fetchVerified("model.gguf", dest, sha, serve(full))
        assertTrue(r.ok)
        assertArrayEquals(full, dest.readBytes())
        assertFalse(HfFiles.partOf(dest).exists())
    }

    @Test fun stalePartFromAnotherRevisionIsDiscardedAndRetriedOnce() = runBlocking {
        val old = ByteArray(2000) { 9 }
        HfFiles.partOf(dest).also { it.parentFile.mkdirs() }.writeBytes(old)   // sisa unduhan revision lama
        var calls = 0
        val r = HfFiles.fetchVerified("model.gguf", dest, sha) { part ->
            calls++
            serve(full)(part)
        }
        assertTrue(r.ok)
        assertEquals(2, calls)
        assertArrayEquals(full, dest.readBytes())
    }

    @Test fun corruptContentFailsAndLeavesNothing() = runBlocking {
        val bad = ByteArray(full.size) { 1 }
        val r = HfFiles.fetchVerified("model.gguf", dest, sha, serve(bad))
        assertFalse(r.ok)
        assertEquals("checksum SHA-256 tidak cocok", r.error)
        assertFalse(dest.exists()); assertFalse(HfFiles.partOf(dest).exists())
    }

    @Test fun alreadyCompleteFileIsKeptWithoutDownloading() = runBlocking {
        dest.parentFile.mkdirs(); dest.writeBytes(full)
        var called = false
        val r = HfFiles.fetchVerified("model.gguf", dest, sha) { called = true }
        assertTrue(r.ok); assertFalse(called)
    }

    @Test fun legacyTruncatedFileAtFinalNameIsReplaced() = runBlocking {
        dest.parentFile.mkdirs(); dest.writeBytes(full.copyOf(1234))   // skema lama: sisa unduhan di nama akhir
        val r = HfFiles.fetchVerified("model.gguf", dest, sha, serve(full))
        assertTrue(r.ok)
        assertArrayEquals(full, dest.readBytes())
    }

    @Test fun withoutChecksumFileIsStillWrittenViaPart() = runBlocking {
        val r = HfFiles.fetchVerified("privacy.json", File(dir, "privacy.json"), null, serve(full))
        assertTrue(r.ok); assertFalse(r.verified)
        assertTrue(File(dir, "privacy.json").isFile)
        assertNull(HfFiles.partOf(File(dir, "privacy.json")).takeIf { it.exists() })
    }
}
