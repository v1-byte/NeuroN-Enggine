package com.neuron.project

import com.neuron.model.AiProject
import com.neuron.model.EngineMode
import kotlinx.serialization.decodeFromString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalOnlyEngineTest {
    @Test
    fun legacy_api_project_json_is_read_as_local() {
        val legacy = """{"name":"default","engine":{"mode":"API","baseUrl":"https://api.openai.com","apiKey":"x","model":"gpt-4o-mini"}}"""
        val p = VirtualTree.json.decodeFromString<AiProject>(legacy)
        assertEquals(EngineMode.LOCAL, p.engine.mode)
    }

    @Test
    fun engine_file_has_no_api_fields() {
        val text = VirtualTree.read(AiProject(name = "default"), "engine/api.json")
        assertFalse(text.contains("baseUrl"))
        assertFalse(text.contains("apiKey"))
        assertTrue(text.contains("LOCAL"))
    }

    @Test
    fun writing_api_mode_to_engine_file_stays_local() {
        val p = VirtualTree.write(
            AiProject(name = "default"), "engine/api.json",
            """{"mode":"API","baseUrl":"http://example.invalid","apiKey":"k"}""",
        ).getOrThrow()
        assertEquals(EngineMode.LOCAL, p.engine.mode)
    }

    @Test
    fun legacy_api_engine_is_detected_but_current_engine_is_not() {
        fun obj(text: String) = kotlinx.serialization.json.Json.parseToJsonElement(text) as kotlinx.serialization.json.JsonObject
        assertTrue(ProjectRepository.isLegacyApiEngine(obj("""{"mode":"API"}""")))
        assertTrue(ProjectRepository.isLegacyApiEngine(obj("""{"mode":"LOCAL","apiKey":"x"}""")))
        assertTrue(ProjectRepository.isLegacyApiEngine(obj("""{"baseUrl":"https://x"}""")))
        assertFalse(ProjectRepository.isLegacyApiEngine(obj("""{"mode":"LOCAL"}""")))
    }

    @Test
    fun repository_reports_legacy_api_on_disk_then_clears_after_resave() {
        val dir = java.nio.file.Files.createTempDirectory("neuron-legacy").toFile()
        try {
            val repo = ProjectRepository(dir)
            java.io.File(dir, "default").mkdirs()
            java.io.File(dir, "default/project.json").writeText(
                """{"name":"default","engine":{"mode":"API","baseUrl":"https://api.openai.com","apiKey":"x","model":"gpt-4o-mini"}}""")
            assertTrue(repo.hasLegacyApiConfig("default"))
            repo.save(repo.loadOrCreate("default"))
            assertFalse(repo.hasLegacyApiConfig("default"))
            assertEquals(EngineMode.LOCAL, repo.loadOrCreate("default").engine.mode)
        } finally { dir.deleteRecursively() }
    }
}
