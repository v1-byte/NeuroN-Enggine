package com.neuron.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** GGUF sintetis tanpa tensor: cukup untuk menguji pembacaan metadata adapter. */
class LoraAdapterTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun le(n: Int) = ByteBuffer.allocate(n).order(ByteOrder.LITTLE_ENDIAN)
    private fun str(s: String): ByteArray { val b = s.toByteArray(); return le(8 + b.size).putLong(b.size.toLong()).put(b).array() }
    private fun u32(v: Int) = le(4).putInt(v).array()
    private fun kvStr(k: String, v: String) = str(k) + u32(8) + str(v)
    private fun kvF32(k: String, v: Float) = str(k) + u32(6) + le(4).putFloat(v).array()

    private fun gguf(name: String, vararg kvs: ByteArray): File {
        val out = ByteArrayOutputStream()
        out.write("GGUF".toByteArray()); out.write(u32(3))
        out.write(le(16).putLong(0).putLong(kvs.size.toLong()).array())
        kvs.forEach { out.write(it) }
        val pad = (32 - out.size() % 32) % 32
        out.write(ByteArray(pad + 32))   // data tensor kosong, selaras 32 byte
        return tmp.newFile(name).also { it.writeBytes(out.toByteArray()) }
    }

    private fun adapter(arch: String = "llama", base: String? = "Llama 3.2 1B Instruct", alpha: Float? = 16f, name: String = "lora.gguf"): File {
        val kvs = mutableListOf(kvStr("general.type", "adapter"), kvStr("adapter.type", "lora"), kvStr("general.architecture", arch))
        if (base != null) kvs += kvStr("general.base_model.0.name", base)
        if (alpha != null) kvs += kvF32("adapter.lora.alpha", alpha)
        return gguf(name, *kvs.toTypedArray())
    }

    private fun baseModel(arch: String = "llama", modelName: String = "Llama-3.2-1B-Instruct", name: String = "base.gguf") =
        GgufReader.read(gguf(name, kvStr("general.architecture", arch), kvStr("general.name", modelName)))

    @Test fun reads_adapter_metadata() {
        val info = LoraAdapter.inspect(adapter())
        assertEquals("llama", info.architecture)
        assertEquals("Llama 3.2 1B Instruct", info.baseModel)
        assertEquals(16.0, info.alpha!!, 0.0001)
    }

    @Test fun alpha_is_optional() {
        assertNull(LoraAdapter.inspect(adapter(alpha = null, name = "a2.gguf")).alpha)
    }

    @Test fun plain_model_is_not_an_adapter() {
        val f = gguf("model.gguf", kvStr("general.architecture", "llama"))
        assertFalse(LoraAdapter.isAdapter(f))
        try { LoraAdapter.inspect(f); fail("harus menolak model biasa") } catch (e: GgufException) {
            assertTrue(e.message!!.contains("bukan adapter"))
        }
    }

    @Test fun rejects_non_lora_adapter_type() {
        val f = gguf("cvec.gguf", kvStr("general.type", "adapter"), kvStr("adapter.type", "control_vector"), kvStr("general.architecture", "llama"))
        try { LoraAdapter.inspect(f); fail() } catch (e: GgufException) { assertTrue(e.message!!.contains("hanya LoRA")) }
    }

    @Test fun legacy_ggla_format_gets_clear_message() {
        val f = tmp.newFile("old.gguf").also { it.writeBytes("ggla".toByteArray() + ByteArray(64)) }
        assertFalse(LoraAdapter.isAdapter(f))
        try { LoraAdapter.inspect(f); fail() } catch (e: GgufException) { assertTrue(e.message!!.contains("ggla")) }
    }

    @Test fun garbage_and_missing_files_are_not_adapters() {
        assertFalse(LoraAdapter.isAdapter(tmp.newFile("junk.gguf").also { it.writeBytes(ByteArray(100) { 7 }) }))
        assertFalse(LoraAdapter.isAdapter(File(tmp.root, "tidak-ada.gguf")))
    }

    @Test fun same_architecture_is_compatible() {
        val v = LoraAdapter.check(LoraAdapter.inspect(adapter()), baseModel())
        assertTrue(v.compatible)
        assertTrue(v.warnings.isEmpty())
    }

    @Test fun architecture_mismatch_is_a_problem() {
        val v = LoraAdapter.check(LoraAdapter.inspect(adapter(arch = "qwen2")), baseModel(arch = "llama"))
        assertFalse(v.compatible)
        assertTrue(v.problems.single().contains("qwen2"))
    }

    @Test fun different_base_name_only_warns() {
        val v = LoraAdapter.check(LoraAdapter.inspect(adapter(base = "Llama 3.1 8B")), baseModel(modelName = "Llama-3.2-1B-Instruct"))
        assertTrue(v.compatible)
        assertEquals(1, v.warnings.size)
    }

    @Test fun missing_base_header_is_a_problem() {
        assertFalse(LoraAdapter.check(LoraAdapter.inspect(adapter()), null).compatible)
    }

    @Test fun adapter_used_as_base_is_a_problem() {
        val asBase = GgufReader.read(adapter(name = "as-base.gguf"))
        assertFalse(LoraAdapter.check(LoraAdapter.inspect(adapter(name = "x.gguf")), asBase).compatible)
    }

    @Test fun model_name_matching_ignores_punctuation_and_case() {
        assertTrue(LoraAdapter.sameModel("Llama 3.2 1B Instruct", "llama-3.2-1b-instruct"))
        assertFalse(LoraAdapter.sameModel("Qwen2.5 3B", "Llama-3.2-1B"))
        assertFalse(LoraAdapter.sameModel("", "Llama"))
    }

    @Test fun scale_must_be_finite_and_in_range() {
        LoraAdapter.requireScale(0f); LoraAdapter.requireScale(1f); LoraAdapter.requireScale(LoraAdapter.MAX_SCALE)
        for (bad in listOf(-0.1f, LoraAdapter.MAX_SCALE + 0.1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            try { LoraAdapter.requireScale(bad); fail("harus menolak $bad") } catch (e: IllegalArgumentException) { assertNotNull(e.message) }
        }
    }
}
