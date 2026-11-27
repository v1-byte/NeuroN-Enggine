package com.neuron.project

import com.neuron.model.AiProject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LoraJsonTest {
    private fun write(json: String) = VirtualTree.write(AiProject(name = "default"), "model/lora.json", json)

    @Test
    fun valid_adapter_and_scale_are_stored() {
        val p = write("""{"path":"/m/loras/a.gguf","scale":0.5}""").getOrThrow()
        assertEquals("/m/loras/a.gguf", p.files.loraPath)
        assertEquals(0.5f, p.files.loraScale, 0f)
    }

    @Test
    fun scale_outside_range_is_rejected() {
        for (bad in listOf("-1", "4.5", "100")) {
            val r = write("""{"path":"/m/loras/a.gguf","scale":$bad}""")
            assertTrue("skala $bad harus ditolak", r.isFailure)
        }
    }

    @Test
    fun empty_path_detaches_adapter() {
        assertEquals("", write("""{"path":"","scale":1.0}""").getOrThrow().files.loraPath)
    }
}
