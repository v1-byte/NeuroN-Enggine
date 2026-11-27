package com.neuron.engine

import com.neuron.model.AiProject
import com.neuron.model.ChatParams
import com.neuron.model.ToolDef
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Engine palsu: tiap panggilan chat() mengembalikan skrip berikutnya, dan mencatat pesan yang diterimanya. */
private class ScriptedEngine(private val replies: List<List<String>>) : InferenceEngine {
    var calls = 0
    val seen = mutableListOf<List<ChatMessage>>()
    override suspend fun load(project: AiProject) {}
    override fun chat(messages: List<ChatMessage>, params: ChatParams): Flow<String> {
        seen += messages.toList()
        return flowOf(*replies[calls++].toTypedArray())
    }
    override suspend fun embed(text: String) = FloatArray(0)
    override suspend fun unload() {}
}

class ToolEngineTest {
    private val calc = BuiltinTools.defs.first { it.name == "calculate" }
    private fun engine(inner: InferenceEngine, tools: List<ToolDef> = listOf(calc)) = ToolEngine(inner, tools, BuiltinTools)
    private fun run(e: InferenceEngine) = runBlocking {
        e.chat(listOf(ChatMessage("user", "berapa 2+3?")), ChatParams()).toList().joinToString("")
    }

    @Test fun plainAnswerPassesThroughWithoutToolCall() {
        val inner = ScriptedEngine(listOf(listOf("Halo ", "dunia")))
        assertEquals("Halo dunia", run(engine(inner)))
        assertEquals(1, inner.calls)
    }

    @Test fun veryShortAnswerThatLooksLikeTagStartIsStillEmitted() {
        val inner = ScriptedEngine(listOf(listOf("<")))
        assertEquals("<", run(engine(inner)))
    }

    @Test fun toolCallIsExecutedAndResultFedBack() {
        val inner = ScriptedEngine(listOf(
            listOf("<tool_call>{\"name\":\"calculate\",", "\"arguments\":{\"expression\":\"2+3\"}}"),
            listOf("Hasilnya ", "5"),
        ))
        val out = run(engine(inner))
        assertTrue(out, out.contains("⚙ calculate({\"expression\":\"2+3\"})"))
        assertTrue(out, out.endsWith("Hasilnya 5"))
        assertEquals(2, inner.calls)
        val fed = inner.seen[1].last()
        assertEquals("user", fed.role)
        assertTrue(fed.content, fed.content.contains("<tool_response>") && fed.content.contains("5"))
    }

    @Test fun unknownToolReturnsErrorToModel() {
        val inner = ScriptedEngine(listOf(
            listOf("<tool_call>{\"name\":\"hapus_semua\",\"arguments\":{}}"),
            listOf("Maaf."),
        ))
        run(engine(inner))
        assertTrue(inner.seen[1].last().content.contains("unknown tool"))
    }

    @Test fun invalidJsonReturnsErrorToModelInsteadOfCrashing() {
        val inner = ScriptedEngine(listOf(
            listOf("<tool_call>{bukan json"),
            listOf("Baik."),
        ))
        val out = run(engine(inner))
        assertTrue(out, out.contains("panggilan alat tidak valid"))
        assertTrue(inner.seen[1].last().content.contains("invalid JSON"))
    }

    @Test fun toolLoopIsBoundedByMaxSteps() {
        val call = listOf("<tool_call>{\"name\":\"current_time\",\"arguments\":{}}")
        // maxSteps default 4 -> 4 putaran tool + 1 jawaban akhir tanpa tool = 5 panggilan; model terus mencoba memanggil tool.
        val inner = ScriptedEngine(List(5) { call })
        val tools = BuiltinTools.defs
        runBlocking { ToolEngine(inner, tools, BuiltinTools).chat(listOf(ChatMessage("user", "x")), ChatParams()).toList() }
        assertEquals(5, inner.calls)
    }
}
