package com.neuron.engine

/** Pembaca header ELF minimal (20 byte pertama) untuk memeriksa arsitektur libneuron_llama.so tanpa memuatnya. */
object ElfInfo {
    class Header(val is64Bit: Boolean, val machine: Int) {
        /** Nama ABI Android untuk arsitektur ini, atau null bila tidak dikenal. */
        val abi: String? get() = when (machine) {
            183 -> "arm64-v8a"
            40 -> "armeabi-v7a"
            62 -> "x86_64"
            3 -> "x86"
            else -> null
        }
    }

    fun parse(head: ByteArray): Header? {
        if (head.size < 20) return null
        if (head[0] != 0x7F.toByte() || head[1] != 'E'.code.toByte() || head[2] != 'L'.code.toByte() || head[3] != 'F'.code.toByte()) return null
        val is64 = head[4].toInt() == 2
        val little = head[5].toInt() == 1
        val lo = head[18].toInt() and 0xFF
        val hi = head[19].toInt() and 0xFF
        val machine = if (little) lo or (hi shl 8) else hi or (lo shl 8)
        return Header(is64, machine)
    }
}
