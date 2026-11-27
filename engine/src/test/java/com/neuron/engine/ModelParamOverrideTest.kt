package com.neuron.engine

import com.neuron.model.AiProject
import com.neuron.model.ChatParams
import com.neuron.model.ModelFiles
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ModelParamOverrideTest {
    private fun proj(path: String = "/m/a.gguf", chat: ChatParams = ChatParams()) =
        AiProject(name = "t", chat = chat, files = ModelFiles(modelPath = path))

    private fun bad(json: String): String {
        try {
            ModelParamOverride.fromJson(json)
        } catch (e: IllegalArgumentException) {
            return e.message ?: ""
        }
        fail("seharusnya ditolak: $json")
        return ""
    }

    @Test fun kosongBerartiTanpaPenimpas() {
        assertTrue(ModelParamOverride.fromJson("").isEmpty)
        assertTrue(ModelParamOverride.fromJson("{}").isEmpty)
        assertTrue(ModelParamOverride.fromJson("""{"temperature":null}""").isEmpty)
    }

    @Test fun bolakBalikJson() {
        val o = ModelParamOverride(temperature = 0.3f, topP = 0.9f, topK = 20, minP = 0.1f, repeatPenalty = 1.2f, maxTokens = 256, seed = 7L, contextLength = 2048)
        assertEquals(o, ModelParamOverride.fromJson(o.toJson()))
    }

    @Test fun hanyaBidangTerisiYangDikirim() {
        val m = ModelParamOverride(topK = 10, seed = 5L).toMap()
        assertEquals(setOf("topK", "seed"), m.keys)
        assertEquals(10, m["topK"])
    }

    @Test fun applyTo_hanyaMenimpasBidangTerisi() {
        val base = ChatParams(temperature = 0.8f, topK = 40, systemPrompt = "S", stopSequences = listOf("x"))
        val r = ModelParamOverride(temperature = 0.2f, contextLength = 1024).applyTo(base)
        assertEquals(0.2f, r.temperature)
        assertEquals(1024, r.contextLength)
        assertEquals(40, r.topK)
        assertEquals("S", r.systemPrompt)
        assertEquals(listOf("x"), r.stopSequences)
    }

    @Test fun nilaiDiLuarRentangDitolak() {
        assertTrue(bad("""{"temperature":6}""").contains("temperature"))
        assertTrue(bad("""{"topP":1.5}""").contains("topP"))
        assertTrue(bad("""{"topK":-1}""").contains("topK"))
        assertTrue(bad("""{"repeatPenalty":0}""").contains("repeatPenalty"))
        assertTrue(bad("""{"maxTokens":0}""").contains("maxTokens"))
        assertTrue(bad("""{"contextLength":128}""").contains("contextLength"))
    }

    @Test fun kunciAsingDanTipeSalahDitolak() {
        assertTrue(bad("""{"top_p":0.5}""").contains("top_p"))
        assertTrue(bad("""{"temperature":"0.5"}""").contains("angka"))
        assertTrue(bad("""{"topK":1.5}""").contains("bulat"))
        assertTrue(bad("[1]").contains("objek"))
    }

    @Test fun effective_penimpasPerModelMenangTapiHanyaUntukModelItu() {
        val prev = ModelDefaults.perModel
        try {
            ModelDefaults.perModel = { path -> if (path == "/m/a.gguf") ModelParamOverride(temperature = 0.1f, contextLength = 2048) else null }
            val a = ModelDefaults.effective(proj("/m/a.gguf", ChatParams(temperature = 0.9f)))
            assertEquals(0.1f, a.temperature)
            assertEquals(2048, a.contextLength)
            val b = ModelDefaults.effective(proj("/m/b.gguf", ChatParams(temperature = 0.9f)))
            assertEquals(0.9f, b.temperature)
            assertEquals(0.9f, ModelDefaults.base(proj("/m/a.gguf", ChatParams(temperature = 0.9f))).temperature)
        } finally {
            ModelDefaults.perModel = prev
        }
    }

    @Test fun effective_tanpaHookSamaDenganBase() {
        val prev = ModelDefaults.perModel
        try {
            ModelDefaults.perModel = null
            assertEquals(ModelDefaults.base(proj()), ModelDefaults.effective(proj()))
            assertNull(ModelDefaults.perModel)
        } finally {
            ModelDefaults.perModel = prev
        }
    }
}
