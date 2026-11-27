package com.neuron.engine

import com.neuron.model.ChatParams
import com.neuron.model.ChatResponseMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatResponsePromptTest {
    @Test fun privateModeAddsPrivacyGuidanceAndKeepsCustomPrompt() {
        val result = ChatResponsePrompt.apply(ChatParams(systemPrompt = "Jawab dalam bahasa Indonesia."), ChatResponseMode.PRIVATE)

        assertTrue(result.systemPrompt.startsWith("Jawab dalam bahasa Indonesia."))
        assertTrue(result.systemPrompt.contains("Mode balasan privat"))
        assertTrue(result.systemPrompt.contains("jangan tampilkan kembali"))
    }

    @Test fun openModeEncouragesBroadAnswersButDoesNotClaimUnrestrictedBehavior() {
        val result = ChatResponsePrompt.apply(ChatParams(systemPrompt = "Base."), ChatResponseMode.OPEN)

        assertTrue(result.systemPrompt.contains("Mode balasan terbuka"))
        assertTrue(result.systemPrompt.contains("guardrail aplikasi"))
        assertTrue(result.systemPrompt.contains("bukan jaminan"))
    }

    @Test fun modeDoesNotMutateOriginalParameters() {
        val original = ChatParams(systemPrompt = "Base.")

        val result = ChatResponsePrompt.apply(original, ChatResponseMode.OPEN)

        assertEquals("Base.", original.systemPrompt)
        assertTrue(result.systemPrompt.startsWith(original.systemPrompt))
    }
}
