package com.neuron.engine

import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Peringatan non-fatal dari engine (mis. template chat tidak dikenali lalu memakai ChatML, riwayat dipangkas).
 * Engine mengirim lewat [post]; bridge mengambilnya dengan [drain] dan meneruskan ke UI sebagai notice,
 * supaya pengguna tahu apa yang terjadi alih-alih hanya melihat jawaban yang aneh.
 */
object EngineWarnings {
    private val queue = ConcurrentLinkedQueue<String>()

    fun post(message: String) {
        if (message.isNotBlank() && !queue.contains(message)) queue.add(message)
    }

    fun drain(): List<String> {
        val out = ArrayList<String>()
        while (true) {
            val next = queue.poll() ?: break
            out.add(next)
        }
        return out
    }
}
