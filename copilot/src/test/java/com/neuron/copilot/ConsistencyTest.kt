package com.neuron.copilot

import com.neuron.model.AiProject
import com.neuron.model.SpecialTokens
import com.neuron.project.VirtualTree
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConsistencyTest {
    private val base = AiProject(name = "test")

    private fun write(p: AiProject, path: String, text: String) = VirtualTree.write(p, path, text).getOrThrow()

    @Test fun default_project_is_consistent() = assertEquals(emptyList<String>(), Consistency.problems(base))

    @Test fun vocab_size_smaller_than_max_id_is_rejected() {
        val p = write(base, "model/config.json", """{"vocab_size": 100}""")
        assertTrue(Consistency.problems(p).any { "vocab_size" in it })
    }

    @Test fun special_token_missing_from_vocab_is_rejected() {
        val p = base.copy(tokenizer = base.tokenizer.copy(special = SpecialTokens(eos = "<|nope|>")))
        assertTrue(Consistency.problems(p).any { "tidak ada di vocab" in it })
    }

    @Test fun eos_id_mismatch_is_rejected() {
        val t = base.tokenizer.copy(special = SpecialTokens(eos = "<|im_end|>"))
        val p = write(base.copy(tokenizer = t), "model/config.json", """{"eos_token_id": 1}""")
        assertTrue(Consistency.problems(p).any { "eos_token_id" in it })
    }

    @Test fun matching_ids_pass() {
        val t = base.tokenizer.copy(special = SpecialTokens(eos = "<|im_end|>"))
        val p = write(base.copy(tokenizer = t), "model/config.json", """{"eos_token_id": 151645, "vocab_size": 151936}""")
        assertEquals(emptyList<String>(), Consistency.problems(p))
    }

    @Test fun apply_change_blocks_new_inconsistency_but_not_preexisting() {
        val old = VirtualTree.read(base, "model/config.json")
        val change = FileChange("model/config.json", old, """{"vocab_size": 100}""")
        assertTrue(CopilotAgent.applyChange(base, change).isFailure)

        val broken = write(base, "model/config.json", """{"vocab_size": 100}""")
        val fix = FileChange("model/config.json", VirtualTree.read(broken, "model/config.json"), """{"vocab_size": 100, "x": 1}""")
        assertTrue(CopilotAgent.applyChange(broken, fix).isSuccess)  // masalah lama, bukan baru
    }
}
