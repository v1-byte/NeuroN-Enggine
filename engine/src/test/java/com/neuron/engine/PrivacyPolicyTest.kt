package com.neuron.engine

import com.neuron.model.PrivacyPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PrivacyPolicyTest {
    @Test fun readsWordsAndRegexByKeyName() {
        val r = PrivacyPolicy.parse("""{"mode":"STRICT","blocked_terms":["Rahasia"," token "],"patterns":["\\d{16}"],"note":"abaikan"}""")
        assertEquals(listOf("Rahasia", "token"), r.words)
        assertEquals(listOf("\\d{16}"), r.regex)
    }

    @Test fun readsNestedObjectsAndItemFields() {
        val r = PrivacyPolicy.parse("""{"rules":{"pii":[{"term":"nik"},{"regex":"[a-z]+@[a-z]+"}]}}""")
        assertEquals(listOf("nik"), r.words)
        assertEquals(listOf("[a-z]+@[a-z]+"), r.regex)
    }

    @Test fun skipsInvalidRegexAndWarns() {
        val r = PrivacyPolicy.parse("""{"regex":["(unclosed","ok.*"]}""")
        assertEquals(listOf("ok.*"), r.regex)
        assertTrue(r.warnings.any { it.contains("tidak valid") })
    }

    @Test fun invalidJsonThrows() {
        val e = runCatching { PrivacyPolicy.parse("{bukan json") }.exceptionOrNull()
        assertTrue(e is IllegalArgumentException)
    }

    @Test fun mergeKeepsOrderWithoutDuplicates() {
        assertEquals(listOf("a", "b", "c"), PrivacyPolicy.merge(listOf("a", "b"), listOf("b", "c")))
    }

    @Test fun documentedSchemaIsReadExactly() {
        val r = PrivacyPolicy.parse(PrivacyPolicy.DOCUMENTED_SCHEMA)
        assertEquals(listOf("kata"), r.words)
        assertEquals(listOf("pola"), r.regex)
        assertTrue(r.warnings.isEmpty())
    }

    @Test fun documentationKeysAreNeverTreatedAsRules() {
        // Kunci seperti word_description / term_examples mengandung kata kunci aturan ("word", "term"),
        // tetapi isinya dokumentasi dan tidak boleh menjadi kata terlarang.
        val schemaKey = "${'$'}schema"
        val r = PrivacyPolicy.parse(
            """{"blocked_terms":["rahasia"],"word_description":["bukan aturan"],"term_examples":["contoh"],"notes":["abaikan"],"$schemaKey":["x"]}"""
        )
        assertEquals(listOf("rahasia"), r.words)
        assertTrue(r.regex.isEmpty())
    }

    @Test fun nonStringValuesAreIgnored() {
        val r = PrivacyPolicy.parse("""{"blocked_terms":[1,true,null,"ok"],"regex":[]}""")
        assertEquals(listOf("ok"), r.words)
    }

    @Test fun unknownSchemaGivesWarningNotCrash() {
        val r = PrivacyPolicy.parse("""{"foo":["bar"]}""")
        assertTrue(r.words.isEmpty() && r.regex.isEmpty())
        assertTrue(r.warnings.any { it.contains("Tidak ada kata atau regex") })
    }

    @Test fun rootArrayOfStringsIsNotGuessed() {
        // Array di akar tanpa nama kunci tidak diketahui jenisnya; tidak boleh ditebak sebagai kata terlarang.
        val r = PrivacyPolicy.parse("""["a","b"]""")
        assertTrue(r.words.isEmpty())
    }

    @Test fun overlongEntryIsSkippedWithWarning() {
        val long = "x".repeat(501)
        val r = PrivacyPolicy.parse("""{"blocked_terms":["$long","ok"]}""")
        assertEquals(listOf("ok"), r.words)
        assertTrue(r.warnings.any { it.contains("500") })
    }

    @Test fun blankAndTooLargeInputThrow() {
        assertTrue(runCatching { PrivacyPolicy.parse("   ") }.exceptionOrNull() is IllegalArgumentException)
        val big = "{\"blocked_terms\":[\"" + "a".repeat(PrivacyPolicy.MAX_BYTES) + "\"]}"
        assertTrue(runCatching { PrivacyPolicy.parse(big) }.exceptionOrNull() is IllegalArgumentException)
    }
}
