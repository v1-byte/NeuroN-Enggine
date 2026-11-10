package com.neuron.engine

import com.neuron.model.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ModelDefaultsTest {
    private fun proj(chat: ChatParams = ChatParams(), mf: String = "", gen: String = "{}", eos: String? = null) =
        AiProject(name = "t", chat = chat, files = ModelFiles(modelfile = mf, generationConfigJson = gen),
            tokenizer = TokenizerConfig(special = SpecialTokens(eos = eos)))

    @Test fun modelfile_parameterDanSystem() {
        val p = ModelDefaults.parseModelfile("FROM x.gguf\n# komentar\nPARAMETER temperature 0.3\nPARAMETER stop \"<|im_end|>\"\nPARAMETER num_ctx 2048\nSYSTEM Jawab singkat.")
        assertEquals(0.3f, p.temperature)
        assertEquals(2048, p.contextLength)
        assertEquals(listOf("<|im_end|>"), p.stop)
        assertEquals("Jawab singkat.", p.system)
    }

    @Test fun modelfile_systemBlokTigaKutip() {
        val p = ModelDefaults.parseModelfile("SYSTEM \"\"\"\nBaris satu\nBaris dua\n\"\"\"")
        assertEquals("Baris satu\nBaris dua", p.system)
    }

    @Test fun modelfile_numPredictNegatifDiabaikan() {
        assertNull(ModelDefaults.parseModelfile("PARAMETER num_predict -1").maxTokens)
    }

    @Test fun generationConfig_dasar() {
        val g = ModelDefaults.parseGenerationConfig("""{"temperature":0.7,"top_p":0.8,"top_k":20,"repetition_penalty":1.05,"max_new_tokens":256}""")
        assertEquals(0.7f, g.temperature); assertEquals(20, g.topK); assertEquals(1.05f, g.repeatPenalty); assertEquals(256, g.maxTokens)
    }

    @Test fun generationConfig_doSampleFalseJadiTemperatureNol() {
        assertEquals(0f, ModelDefaults.parseGenerationConfig("""{"do_sample":false,"temperature":0.7}""").temperature)
    }

    @Test fun generationConfig_rusakAmanDanKosong() {
        assertNull(ModelDefaults.parseGenerationConfig("bukan json").temperature)
        assertNull(ModelDefaults.parseGenerationConfig("{}").topP)
    }

    @Test fun effective_paramsJsonYangSudahDiubahMenang() {
        val e = ModelDefaults.effective(proj(chat = ChatParams(temperature = 0.1f), mf = "PARAMETER temperature 0.9", gen = """{"temperature":0.5}"""))
        assertEquals(0.1f, e.temperature)
    }

    @Test fun effective_modelfileMengalahkanGenerationConfig() {
        val e = ModelDefaults.effective(proj(mf = "PARAMETER top_k 10", gen = """{"top_k":99,"top_p":0.5}"""))
        assertEquals(10, e.topK); assertEquals(0.5f, e.topP)
    }

    @Test fun effective_bawaanBilaTidakAdaSumberLain() {
        assertEquals(ChatParams(), ModelDefaults.effective(proj()))
    }

    @Test fun effective_eosMenjadiStopTanpaGanda() {
        val e = ModelDefaults.effective(proj(chat = ChatParams(stopSequences = listOf("<|im_end|>")), mf = "PARAMETER stop \"<|im_end|>\"", eos = "<|im_end|>"))
        assertEquals(listOf("<|im_end|>"), e.stopSequences)
    }
}
