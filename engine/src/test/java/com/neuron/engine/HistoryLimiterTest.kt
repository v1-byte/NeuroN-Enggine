package com.neuron.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class HistoryLimiterTest {
    private fun convo(n: Int, size: Int = 20): List<ChatMessage> =
        (0 until n).map { ChatMessage(if (it % 2 == 0) "user" else "assistant", "pesan$it " + "x".repeat(size)) }

    @Test
    fun short_history_is_untouched() {
        val m = convo(5)
        val r = HistoryLimiter.limit(m, 4096, 512, "You are helpful.")
        assertEquals(5, r.messages.size)
        assertEquals(0, r.dropped)
    }

    @Test
    fun message_count_is_capped_and_newest_kept() {
        val m = convo(41)   // pesan terakhir bertipe user (indeks genap)
        val r = HistoryLimiter.limit(m, 32768, 512, "")
        assertTrue(r.messages.size <= HistoryLimiter.MAX_MESSAGES)
        assertEquals(m.last(), r.messages.last())
        assertEquals(m.size - r.messages.size, r.dropped)
    }

    @Test
    fun token_budget_drops_oldest_first() {
        val m = convo(10, size = 900)   // ~300 token per pesan
        val r = HistoryLimiter.limit(m, 1024, 128, "")
        assertTrue(r.dropped > 0)
        assertEquals(m.last(), r.messages.last())
        assertTrue(r.messages.sumOf { HistoryLimiter.estimateTokens(it.content) } < 1024)
    }

    @Test
    fun never_starts_with_orphan_assistant_reply() {
        val r = HistoryLimiter.limit(convo(30), 32768, 512, "", maxMessages = 6)
        assertEquals("user", r.messages.first().role)
    }

    @Test
    fun single_oversized_message_is_a_context_error() {
        val big = listOf(ChatMessage("user", "y".repeat(20_000)))
        try {
            HistoryLimiter.limit(big, 2048, 256, "")
            fail("harus melempar EngineException")
        } catch (e: EngineException) {
            assertEquals(EngineErrorKind.CONTEXT, e.kind)
        }
    }

    @Test
    fun tiny_context_is_a_context_error() {
        try {
            HistoryLimiter.limit(convo(1), 128, 512, "system " + "s".repeat(600))
            fail("harus melempar EngineException")
        } catch (e: EngineException) {
            assertEquals(EngineErrorKind.CONTEXT, e.kind)
        }
    }
}
