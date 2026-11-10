package com.neuron.project

import com.neuron.model.AiProject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ExplorerSectionsTest {
    private val listed: List<String>
        get() = ExplorerSections.groups().flatMap { s -> s.files.map { it.path } }

    @Test
    fun every_virtual_file_is_listed_exactly_once() {
        assertEquals(VirtualTree.paths.sorted(), listed.sorted())
    }

    @Test
    fun no_file_is_listed_twice() {
        assertEquals(listed.size, listed.toSet().size)
    }

    @Test
    fun there_are_seven_numbered_sections() {
        val numbered = ExplorerSections.groups().filter { it.title.first().isDigit() }
        assertEquals(7, numbered.size)
    }

    /** Setiap parameter yang punya key harus benar-benar ada di JSON file-nya, supaya lompatan tidak gagal. */
    @Test
    fun every_param_key_exists_in_its_file() {
        val project = AiProject(name = "test")
        for (group in ExplorerSections.groups()) for (file in group.files) for (param in file.params) {
            val key = param.key ?: continue
            val text = VirtualTree.read(project, file.path)
            assertTrue("${file.path} tidak memuat \"$key\" (${param.label})", text.contains("\"$key\""))
        }
    }
}
