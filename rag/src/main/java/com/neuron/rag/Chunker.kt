package com.neuron.rag

/** Memecah teks per kalimat/baris (bukan memotong di tengah kata), dengan overlap antar-chunk. Ukuran dalam karakter. */
object Chunker {
    private val paraSplit = Regex("\n{2,}")
    private val sentSplit = Regex("(?<=[.!?。])\\s+|\\n")

    fun split(text: String, size: Int, overlap: Int): List<String> {
        val clean = text.replace("\r\n", "\n").trim()
        if (clean.isEmpty()) return emptyList()

        val units = ArrayList<String>()
        for (para in clean.split(paraSplit)) {
            for (s in para.split(sentSplit)) {
                val t = s.trim()
                if (t.isEmpty()) continue
                if (t.length <= size) units += t else t.chunked(size).forEach { units += it }   // satu kalimat sangat panjang
            }
        }

        val out = ArrayList<String>()
        val cur = StringBuilder()
        for (u in units) {
            if (cur.isNotEmpty() && cur.length + 1 + u.length > size) {
                out += cur.toString()
                val tail = overlapTail(cur, overlap)
                cur.setLength(0)
                if (tail.isNotEmpty() && tail.length + 1 + u.length <= size) cur.append(tail)
            }
            if (cur.isNotEmpty()) cur.append(' ')
            cur.append(u)
        }
        if (cur.isNotBlank()) out += cur.toString()
        return out
    }

    /** Ekor chunk (maks `overlap` karakter) dimulai pada batas kata. Kosong jika chunk lebih pendek dari overlap. */
    private fun overlapTail(sb: CharSequence, overlap: Int): String {
        if (overlap <= 0 || sb.length <= overlap) return ""
        val s = sb.toString()
        val from = s.length - overlap
        val sp = s.indexOf(' ', from)
        return if (sp < 0) "" else s.substring(sp + 1)
    }
}
