package com.neuron.engine

import com.neuron.model.ChatParams
import com.neuron.model.ChatResponseMode

/** Instruksi gaya balasan untuk chat lokal; guardrail input/output tetap dijalankan terpisah. */
object ChatResponsePrompt {
    fun apply(params: ChatParams, mode: ChatResponseMode): ChatParams {
        val instruction = when (mode) {
            ChatResponseMode.PRIVATE ->
                "Mode balasan privat: perlakukan percakapan sebagai konteks pribadi. Hindari mengulang token, kata sandi, kredensial, atau data sangat sensitif. Jika pesan memuat rahasia, jangan tampilkan kembali; minta pengguna menyamarkannya dan tetap bantu bagian aman yang tidak memerlukan rahasia tersebut."
            ChatResponseMode.OPEN ->
                "Mode balasan terbuka: jawab pertanyaan yang beragam secara langsung, ramah, dan informatif; jangan menolak permintaan yang wajar dan aman tanpa alasan relevan. Tetap ikuti guardrail aplikasi dan batas keselamatan yang berlaku. Mode ini bukan jaminan bahwa semua permintaan dapat dijawab."
        }
        val base = params.systemPrompt.trimEnd()
        return params.copy(systemPrompt = if (base.isEmpty()) instruction else "$base\n\n$instruction")
    }
}
