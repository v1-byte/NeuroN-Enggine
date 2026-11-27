package com.neuron.project

import com.neuron.model.AiProject
import com.neuron.model.ChatResponseMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FeatureConfigJsonTest {
    @Test fun providedFeatureShapePersistsPrivacyModeAndGuardrails() {
        val input = """
            {
              "tools": [],
              "visionEnabled": false,
              "mmprojPath": "",
              "ttsEnabled": false,
              "sttEnabled": false,
              "voiceLanguage": "id",
              "responseMode": "private",
              "guardrailRegex": ["\\bgh[pousr]_[A-Za-z0-9_]{20,}\\b", "\\bhf_[A-Za-z0-9]{20,}\\b", "\\b\\d{16}\\b"],
              "guardrailBlockedWords": ["API_KEY_RAHASIA", "PASSWORD_INTERNAL", "TOKEN_INTERNAL"]
            }
        """.trimIndent()

        val project = VirtualTree.write(AiProject(name = "test"), "features/features.json", input).getOrThrow()
        val stored = VirtualTree.read(project, "features/features.json")

        assertEquals(ChatResponseMode.PRIVATE, project.features.responseMode)
        assertEquals(3, project.features.guardrailRegex.size)
        assertEquals(listOf("API_KEY_RAHASIA", "PASSWORD_INTERNAL", "TOKEN_INTERNAL"), project.features.guardrailBlockedWords)
        assertTrue(stored.contains("\"responseMode\": \"private\""))
    }

    @Test fun olderFeatureJsonDefaultsToOpenResponseMode() {
        val project = VirtualTree.write(
            AiProject(name = "test"),
            "features/features.json",
            """{"tools":[],"guardrailRegex":[],"guardrailBlockedWords":[]}""",
        ).getOrThrow()

        assertEquals(ChatResponseMode.OPEN, project.features.responseMode)
    }
}
