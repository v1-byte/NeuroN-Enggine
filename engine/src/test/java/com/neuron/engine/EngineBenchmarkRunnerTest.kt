package com.neuron.engine

import com.neuron.model.AiProject
import com.neuron.model.ChatParams
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

private class BenchmarkFakeEngine : InferenceEngine {
    val paramsSeen = mutableListOf<ChatParams>()
    override suspend fun load(project: AiProject) {}
    override fun chat(messages: List<ChatMessage>, params: ChatParams): Flow<String> = flow {
        paramsSeen += params
        emit("OK")
        emit("!")
    }
    override suspend fun embed(text: String) = FloatArray(0)
    override suspend fun unload() {}
    override val lastStats = GenStats(completionTokens = 3, millis = 250)
}

class EngineBenchmarkRunnerTest {
    @Test
    fun reportsLatencyOutputAndDeterministicSampling() = runBlocking {
        val engine = BenchmarkFakeEngine()
        val results = EngineBenchmarkRunner(engine).run(
            AiProject(name = "benchmark-test"), prompts = listOf("prompt uji"), maxTokens = 32,
        )

        assertEquals(1, results.size)
        val sample = results.single()
        assertEquals(3, sample.outputCharacters)
        assertEquals("OK!", sample.outputPreview)
        assertTrue(sample.elapsedMillis > 0)
        assertNotNull(sample.timeToFirstTokenMillis)
        assertEquals(12.0, sample.tokensPerSecond!!, 0.001)
        assertEquals(0f, engine.paramsSeen.single().temperature, 0f)
        assertEquals(1f, engine.paramsSeen.single().topP, 0f)
        assertEquals(42L, engine.paramsSeen.single().seed)
        assertEquals(32, engine.paramsSeen.single().maxTokens)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsEmptyPromptList() {
        runBlocking {
            EngineBenchmarkRunner(BenchmarkFakeEngine()).run(AiProject(name = "benchmark-test"), prompts = emptyList())
        }
    }
}
