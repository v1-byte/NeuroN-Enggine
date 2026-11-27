package com.neuron.project

import com.neuron.model.AiProject
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
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

    /**
     * True bila project.json di disk masih membawa konfigurasi API lama (engine.mode "API", baseUrl, apiKey, atau model).
     * Konfigurasi itu TIDAK dipakai: AiProject hanya mengenal mode lokal dan bidang lama dibuang saat dibaca.
     * Dipakai UI untuk memberi tahu pengguna, bukan untuk mengaktifkan apa pun.
     */
    fun hasLegacyApiConfig(name: String): Boolean {
        val f = file(name)
        if (!f.exists()) return false
        return runCatching {
            val engine = (Json.parseToJsonElement(f.readText()) as? JsonObject)?.get("engine") as? JsonObject
            engine != null && isLegacyApiEngine(engine)
        }.getOrDefault(false)
    }

    fun save(p: AiProject) {
        val f = file(p.name).also { it.parentFile!!.mkdirs() }
        val tmp = File(f.parentFile, "project.json.tmp")
        tmp.writeText(json.encodeToString(p))
        tmp.renameTo(f)        // tulis atomik supaya tidak korup saat app mati
    }

    companion object {
        /** Objek `engine` gaya lama: mode API atau salah satu bidang baseUrl/apiKey/model. */
        fun isLegacyApiEngine(engine: JsonObject): Boolean =
            (engine["mode"] as? JsonPrimitive)?.content.equals("API", ignoreCase = true) ||
                listOf("baseUrl", "apiKey", "model").any { it in engine }
    }
    // TODO: import/export zip proyek, riwayat versi (undo)
}
