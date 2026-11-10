package com.neuron.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TextTest {
    @Test fun utf8_twoByteCharSplitAcrossTokens() {
        val d = Utf8Stream()
        assertEquals("", d.push(byteArrayOf(0xC3.toByte())))
        assertEquals("é", d.push(byteArrayOf(0xA9.toByte())))
    }

    @Test fun utf8_emojiSplitInTwo() {
        val d = Utf8Stream()
        assertEquals("", d.push(byteArrayOf(0xF0.toByte(), 0x9F.toByte())))
        assertEquals("😀", d.push(byteArrayOf(0x98.toByte(), 0x80.toByte())))
    }

    @Test fun utf8_asciiPassesThroughImmediately() {
        assertEquals("halo", Utf8Stream().push("halo".toByteArray()))
    }

    @Test fun stop_holdsPossiblePrefixThenCuts() {
        val m = StopMatcher(listOf("</s>"))
        assertEquals("Hello ", m.feed("Hello <"))
        assertFalse(m.stopped)
        assertEquals("", m.feed("/s> tail"))
        assertTrue(m.stopped)
        assertEquals("", m.flush())
    }

    @Test fun stop_inMiddleOfChunk() {
        val m = StopMatcher(listOf("</s>"))
        assertEquals("abc", m.feed("abc</s>def"))
        assertTrue(m.stopped)
    }

    @Test fun stop_flushReleasesHeldTailWhenNoStopComes() {
        val m = StopMatcher(listOf("</s>"))
        assertEquals("x", m.feed("x<"))
        assertEquals("<", m.flush())
    }

    @Test fun stop_noStopsIsPassthrough() {
        assertEquals("apa saja", StopMatcher(emptyList()).feed("apa saja"))
    }
}
