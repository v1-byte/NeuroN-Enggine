package com.neuron.engine

/** Potongan token dari native adalah byte UTF-8 mentah; satu karakter bisa terpecah antar token. */
class Utf8Stream {
    private var pending = ByteArray(0)
    fun push(b: ByteArray): String {
        val all = pending + b
        val cut = completeLen(all)
        pending = all.copyOfRange(cut, all.size)
        return String(all, 0, cut, Charsets.UTF_8)
    }
    fun flush(): String = String(pending, Charsets.UTF_8).also { pending = ByteArray(0) }

    private fun completeLen(a: ByteArray): Int {
        var i = a.size - 1; var back = 0
        while (i >= 0 && back < 4 && (a[i].toInt() and 0xC0) == 0x80) { i--; back++ }
        if (i < 0) return a.size
        val lead = a[i].toInt() and 0xFF
        val need = when { lead >= 0xF0 -> 4; lead >= 0xE0 -> 3; lead >= 0xC0 -> 2; else -> 1 }
        return if (need > back + 1) i else a.size
    }
}

/** Memotong output tepat sebelum stop sequence; menahan ekor yang mungkin awal dari stop sequence. */
class StopMatcher(private val stops: List<String>) {
    private var buf = StringBuilder()
    var stopped = false; private set

    fun feed(text: String): String {
        if (stops.isEmpty()) return text
        buf.append(text)
        val s = buf.toString()
        var hit = -1
        for (st in stops) if (st.isNotEmpty()) { val i = s.indexOf(st); if (i >= 0 && (hit < 0 || i < hit)) hit = i }
        if (hit >= 0) { stopped = true; buf = StringBuilder(); return s.substring(0, hit) }
        var hold = 0
        for (st in stops) for (k in minOf(st.length - 1, s.length) downTo 1) if (s.endsWith(st.substring(0, k))) { hold = maxOf(hold, k); break }
        buf = StringBuilder(s.substring(s.length - hold))
        return s.substring(0, s.length - hold)
    }
    fun flush(): String = if (stopped) "" else buf.toString().also { buf = StringBuilder() }
}
