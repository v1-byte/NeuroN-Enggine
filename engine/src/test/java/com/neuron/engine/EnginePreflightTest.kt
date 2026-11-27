package com.neuron.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class EnginePreflightTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun kindOf(block: () -> Unit): EngineErrorKind {
        try { block() } catch (e: EngineException) { return e.kind }
        fail("harus melempar EngineException"); throw IllegalStateException()
    }

    @Test
    fun elf_header_reports_arm64() {
        val h = ByteArray(20)
        h[0] = 0x7F; h[1] = 'E'.code.toByte(); h[2] = 'L'.code.toByte(); h[3] = 'F'.code.toByte()
        h[4] = 2; h[5] = 1; h[18] = 183.toByte(); h[19] = 0
        val elf = ElfInfo.parse(h)
        assertNotNull(elf)
        assertEquals("arm64-v8a", elf!!.abi)
        assertTrue(elf.is64Bit)
    }

    @Test
    fun elf_rejects_garbage_and_short_input() {
        assertEquals(null, ElfInfo.parse(ByteArray(20)))
        assertEquals(null, ElfInfo.parse(ByteArray(4)))
    }

    @Test
    fun missing_or_blank_model_is_a_model_error() {
        assertEquals(EngineErrorKind.MODEL, kindOf { EnginePreflight.checkModelFile("") })
        assertEquals(EngineErrorKind.MODEL, kindOf { EnginePreflight.checkModelFile("/tidak/ada.gguf") })
    }

    @Test
    fun non_gguf_content_is_a_model_error() {
        val f = tmp.newFile("fake.gguf")
        f.writeBytes(ByteArray(1_200_000) { 'A'.code.toByte() })
        assertEquals(EngineErrorKind.MODEL, kindOf { EnginePreflight.checkModelFile(f.path) })
    }

    @Test
    fun truncated_download_is_a_model_error() {
        val f = tmp.newFile("small.gguf")
        f.writeBytes("GGUF".toByteArray())
        assertEquals(EngineErrorKind.MODEL, kindOf { EnginePreflight.checkModelFile(f.path) })
    }

    @Test
    fun valid_gguf_header_passes_and_returns_size() {
        val f = tmp.newFile("ok.gguf")
        f.writeBytes("GGUF".toByteArray() + ByteArray(1_200_000))
        assertEquals(f.length(), EnginePreflight.checkModelFile(f.path))
        assertTrue(EnginePreflight.isGgufMagic("GGUF".toByteArray()))
        assertFalse(EnginePreflight.isGgufMagic("GGML".toByteArray()))
    }

    @Test
    fun ram_check_blocks_only_when_estimate_exceeds_available() {
        EnginePreflight.checkRam(2_000_000_000L, 4096, "f16", 4_000_000_000L)   // cukup
        EnginePreflight.checkRam(2_000_000_000L, 4096, "f16", null)             // tidak diketahui: lewati
        assertEquals(EngineErrorKind.RAM, kindOf { EnginePreflight.checkRam(3_000_000_000L, 4096, "f16", 3_200_000_000L) })
    }

    @Test
    fun smaller_kv_type_needs_less_ram() {
        assertTrue(EnginePreflight.kvBytesPerToken("q4_0") < EnginePreflight.kvBytesPerToken("q8_0"))
        assertTrue(EnginePreflight.kvBytesPerToken("q8_0") < EnginePreflight.kvBytesPerToken("f16"))
    }
}
