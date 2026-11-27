package com.neuron.rag

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.io.InputStream
import java.util.zip.ZipInputStream

/**
 * Membaca file pengetahuan menjadi teks. Didukung: teks/markdown/csv/json/kode, .docx, .pdf (pdfbox-android).
 * Jalur: path absolut, path relatif (terhadap folder knowledge app), direktori (rekursif), atau content:// (SAF).
 * Folder knowledge app: Android/data/<paket>/files/knowledge/  ("." = seluruh folder itu).
 */
class FileParser(private val ctx: Context) {
    val baseDir: File = (ctx.getExternalFilesDir("knowledge") ?: File(ctx.filesDir, "knowledge")).also { it.mkdirs() }

    private val textExt = setOf("txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "xml", "html", "htm", "log",
        "kt", "java", "py", "js", "ts", "c", "cpp", "h", "yaml", "yml", "toml", "ini", "sql", "tex", "rst", "")
    private val allExt = textExt + setOf("docx", "pdf")
    private val maxBytes = 25L * 1024 * 1024

    private fun isUri(p: String) = p.startsWith("content://")
    private fun fileOf(p: String): File = File(p).let { if (it.isAbsolute) it else File(baseDir, p) }

    /** Ubah daftar entri (file/direktori) menjadi daftar file yang bisa dibaca, urut stabil. */
    fun expand(entries: List<String>): List<String> {
        val out = LinkedHashSet<String>()
        for (e in entries.map { it.trim() }.filter { it.isNotEmpty() }) {
            if (isUri(e)) { out += e; continue }
            val f = fileOf(e)
            when {
                f.isDirectory -> f.walkTopDown().filter { it.isFile && it.extension.lowercase() in allExt && !it.name.startsWith(".") }
                    .sortedBy { it.path }.forEach { out += it.absolutePath }
                f.isFile -> out += f.absolutePath
            }
        }
        return out.toList()
    }

    fun displayName(path: String): String {
        if (!isUri(path)) return File(path).name
        return runCatching {
            ctx.contentResolver.query(Uri.parse(path), arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            }
        }.getOrNull() ?: path.substringAfterLast('/')
    }

    private fun open(path: String): InputStream =
        if (isUri(path)) ctx.contentResolver.openInputStream(Uri.parse(path)) ?: error("Tidak bisa membuka $path")
        else File(path).also { require(it.length() <= maxBytes) { "File terlalu besar (>25 MB): ${it.name}" } }.inputStream()

    fun read(path: String): String {
        val ext = displayName(path).substringAfterLast('.', "").lowercase()
        return open(path).use { input ->
            when (ext) {
                "pdf" -> PdfText.extract(ctx, input)
                "docx" -> DocxText.extract(input)
                in textExt -> input.readBytes().toString(Charsets.UTF_8)
                else -> error("Format .$ext belum didukung")
            }
        }
    }
}

/** .docx = zip; teks ada di word/document.xml. */
object DocxText {
    fun extract(input: InputStream): String {
        ZipInputStream(input).use { zip ->
            while (true) {
                val e = zip.nextEntry ?: break
                if (e.name == "word/document.xml") {
                    val xml = zip.readBytes().toString(Charsets.UTF_8)
                    return xml.replace("</w:p>", "\n").replace(Regex("<w:tab/>"), " ")
                        .replace(Regex("<[^>]+>"), "")
                        .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
                        .replace("&quot;", "\"").replace("&apos;", "'")
                }
            }
        }
        error("word/document.xml tidak ditemukan (bukan .docx valid?)")
    }
}

/** Dipisah agar mudah dibuang jika tidak mau dependensi pdfbox-android. */
object PdfText {
    private var inited = false
    fun extract(ctx: Context, input: InputStream): String {
        if (!inited) { com.tom_roush.pdfbox.android.PDFBoxResourceLoader.init(ctx.applicationContext); inited = true }
        com.tom_roush.pdfbox.pdmodel.PDDocument.load(input).use { doc ->
            return com.tom_roush.pdfbox.text.PDFTextStripper().getText(doc)
        }
    }
}
