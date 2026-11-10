package com.neuron.project

import com.neuron.model.AiProject
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import java.io.File

class ProjectRepository(private val root: File) {
    private val json = VirtualTree.json
    private fun file(name: String) = File(root, "$name/project.json")

    fun list(): List<String> = root.listFiles()?.filter { it.isDirectory }?.map { it.name } ?: emptyList()

    fun loadOrCreate(name: String): AiProject {
        val f = file(name)
        if (!f.exists()) return AiProject(name = name).also { save(it) }
        return runCatching { json.decodeFromString<AiProject>(f.readText()) }
            .getOrElse { f.copyTo(File(f.parentFile, "project.broken.json"), overwrite = true); AiProject(name = name).also { save(it) } }
    }

    fun save(p: AiProject) {
        val f = file(p.name).also { it.parentFile!!.mkdirs() }
        val tmp = File(f.parentFile, "project.json.tmp")
        tmp.writeText(json.encodeToString(p))
        tmp.renameTo(f)        // tulis atomik supaya tidak korup saat app mati
    }
    // TODO: import/export zip proyek, riwayat versi (undo)
}
