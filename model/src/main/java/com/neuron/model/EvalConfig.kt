package com.neuron.model

import kotlinx.serialization.Serializable

/** 8. Eval: kasus uji untuk membandingkan sebelum/sesudah perubahan (dipakai Copilot). File: eval/cases.json */
@Serializable
data class EvalCase(
    val name: String = "",
    val prompt: String,
    val mustContain: List<String> = emptyList(),     // semua harus muncul (tanpa membedakan huruf besar/kecil)
    val mustNotContain: List<String> = emptyList(),  // tidak boleh muncul
)

@Serializable
data class EvalConfig(
    val cases: List<EvalCase> = emptyList(),
    val maxTokens: Int = 256,
)

fun EvalConfig.validate() {
    require(maxTokens in 1..4096) { "eval.maxTokens harus 1..4096" }
    cases.forEachIndexed { i, c -> require(c.prompt.isNotBlank()) { "eval.cases[$i].prompt tidak boleh kosong" } }
}
