package com.neuron.engine

/** Renderer sederhana (ChatML). TODO: interpreter Jinja minimal atau pakai llama_chat_apply_template dari native. */
object ChatTemplate {
    fun render(msgs: List<ChatMessage>, system: String): String = buildString {
        append("<|im_start|>system\n$system<|im_end|>\n")
        msgs.forEach { append("<|im_start|>${it.role}\n${it.content}<|im_end|>\n") }
        append("<|im_start|>assistant\n")
    }
}
