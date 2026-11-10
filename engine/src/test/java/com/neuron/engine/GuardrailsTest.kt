package com.neuron.engine

import com.neuron.model.FeatureConfig
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GuardrailsTest {
    private fun words(vararg w: String) = Guardrails(FeatureConfig(guardrailBlockedWords = w.toList()))

    @Test fun inactiveWhenNothingConfigured() {
        val g = Guardrails(FeatureConfig())
        assertFalse(g.active)
        assertNull(g.checkInput("apa saja"))
    }

    @Test fun invalidRegexIsIgnoredNotCrashing() {
        val g = Guardrails(FeatureConfig(guardrailRegex = listOf("[")))
        assertFalse(g.active)
    }

    @Test fun inputBlockedCaseInsensitive() {
        val g = words("rahasia")
        assertEquals(Guardrails.BLOCKED_INPUT, g.checkInput("Ini RAHASIA negara"))
        assertNull(g.checkInput("aman saja"))
    }

    @Test fun regexBlocksCardNumber() {
        val g = Guardrails(FeatureConfig(guardrailRegex = listOf("\\b\\d{16}\\b")))
        assertEquals(Guardrails.BLOCKED_INPUT, g.checkInput("kartu 1234567890123456"))
        assertNull(g.checkInput("kode 12345"))
    }

    @Test fun outputSafeTextPassesUnchanged() = runBlocking {
        val out = words("rahasia").filter(flowOf("halo ", "dunia")).toList().joinToString("")
        assertEquals("halo dunia", out)
    }

    @Test fun outputWordSplitAcrossTokensIsCaughtBeforeShown() = runBlocking {
        val out = words("rahasia").filter(flowOf("ra", "ha", "sia")).toList().joinToString("")
        assertEquals(Guardrails.BLOCKED_OUTPUT, out)
    }

    @Test fun outputEarlierSafeTextIsNotLeakedBeforeBlock() = runBlocking {
        val out = words("rahasia").filter(flowOf("kata sandinya adalah ", "rahasia", " besar")).toList().joinToString("")
        assertTrue(out.endsWith(Guardrails.BLOCKED_OUTPUT))
        assertFalse(out.contains("rahasia"))
    }
}
