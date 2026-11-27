package com.neuron.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineErrorsTest {
    @Test
    fun native_tags_map_to_kinds_and_are_stripped() {
        val cases = mapOf(
            "[MODEL] file rusak" to EngineErrorKind.MODEL,
            "[RAM] KV cache gagal" to EngineErrorKind.RAM,
            "[CONTEXT] decode gagal" to EngineErrorKind.CONTEXT,
            "[NATIVE] JNI beda" to EngineErrorKind.NATIVE,
        )
        for ((raw, kind) in cases) {
            val e = EngineErrors.classify(RuntimeException(raw))
            assertEquals(kind, e.kind)
            assertTrue(!e.message!!.startsWith("["))
        }
    }

    @Test
    fun engine_exception_passes_through_unchanged() {
        val original = EngineException(EngineErrorKind.CANCELLED, "dibatalkan")
        assertSame(original, EngineErrors.classify(original))
    }

    @Test
    fun jvm_errors_are_classified() {
        assertEquals(EngineErrorKind.NATIVE, EngineErrors.classify(UnsatisfiedLinkError("no symbol")).kind)
        assertEquals(EngineErrorKind.RAM, EngineErrors.classify(OutOfMemoryError()).kind)
    }

    @Test
    fun untagged_errors_stay_unknown_with_legacy_code() {
        val e = EngineErrors.classify(IllegalStateException("aneh"))
        assertEquals(EngineErrorKind.UNKNOWN, e.kind)
        assertEquals("CHAT_ERROR", e.kind.code)
        assertEquals("aneh", e.message)
    }

    @Test
    fun codes_are_distinct_per_kind() {
        val codes = EngineErrorKind.values().map { it.code }
        assertEquals(codes.size, codes.toSet().size)
    }
}
