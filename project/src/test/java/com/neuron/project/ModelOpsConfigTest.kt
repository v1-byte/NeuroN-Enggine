package com.neuron.project

import com.neuron.model.ModelOp
import com.neuron.model.ModelOpsConfig
import com.neuron.model.validate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelOpsConfigTest {
    private fun ok(c: ModelOpsConfig) = c.validate()
    private fun bad(c: ModelOpsConfig): String = assertThrows(IllegalArgumentException::class.java) { c.validate() }.message.orEmpty()

    @Test fun quantizeButuhSumberOutputGgufDanTipe() {
        ok(ModelOpsConfig(op = ModelOp.QUANTIZE, source = "m.gguf", output = "outputs/m-Q4_K_M.gguf", quantization = "Q4_K_M"))
        bad(ModelOpsConfig(op = ModelOp.QUANTIZE, source = "", output = "o.gguf"))
        bad(ModelOpsConfig(op = ModelOp.QUANTIZE, source = "m.gguf", output = "o.bin"))
        bad(ModelOpsConfig(op = ModelOp.QUANTIZE, source = "m.gguf", output = "o.gguf", quantization = ""))
    }

    @Test fun kuantisasiUlangMatiSecaraDefault() {
        assertFalse(ModelOpsConfig().allowRequantize)
        assertEquals(1.0, ModelOpsConfig().loraScale, 0.0)
    }

    @Test fun mergeLoraGgufMemeriksaAdapterOutputDanSkala() {
        val base = ModelOpsConfig(op = ModelOp.MERGE_LORA_GGUF, source = "base.gguf", adapter = "lora.gguf", output = "outputs/merged.gguf")
        ok(base)
        ok(base.copy(loraScale = 0.0))
        ok(base.copy(loraScale = 4.0))
        bad(base.copy(adapter = ""))
        bad(base.copy(source = ""))
        bad(base.copy(output = "outputs/merged"))
        bad(base.copy(loraScale = -0.1))
        bad(base.copy(loraScale = 4.1))
        bad(base.copy(loraScale = Double.NaN))
    }

    @Test fun mergeModelsButuhMinimalDuaSumberDanBobotPositif() {
        val c = ModelOpsConfig(op = ModelOp.MERGE_MODELS, mergeSources = listOf("a", "b"), output = "pipeline/x-hf")
        ok(c)
        ok(c.copy(mergeWeights = listOf(0.7, 0.3)))
        bad(c.copy(mergeSources = listOf("a")))
        bad(c.copy(output = ""))
        bad(c.copy(mergeWeights = listOf(1.0)))
        bad(c.copy(mergeWeights = listOf(1.0, 0.0)))
        bad(c.copy(mergeWeights = listOf(1.0, -2.0)))
        assertTrue(bad(c.copy(mergeWeights = listOf(1.0, Double.NaN))).contains("mergeWeights"))
    }

    @Test fun mergeModelsOutputBolehFolder() {
        // folder HF (bukan .gguf) sah: hasil akhir di HP dibuat lewat konversi lalu unduh GGUF.
        ok(ModelOpsConfig(op = ModelOp.MERGE_MODELS, mergeSources = listOf("a", "b"), output = "pipeline/x-hf"))
    }
}
