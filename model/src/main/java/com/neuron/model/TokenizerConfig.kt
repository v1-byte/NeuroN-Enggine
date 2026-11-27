package com.neuron.model
import kotlinx.serialization.Serializable

/** 3. Tokenizer -> tokenizer/tokenizer.json (special tokens) & tokenizer/vocab.json (vocab) */
@Serializable
data class SpecialTokens(val bos: String? = null, val eos: String? = null, val pad: String? = null, val unk: String? = null, val extra: Map<String, String> = emptyMap())
@Serializable
data class TokenizerConfig(
    val vocabPath: String = "",
    val special: SpecialTokens = SpecialTokens(),
    val vocabJson: String = "{\n  \"<|endoftext|>\": 151643,\n  \"<|im_start|>\": 151644,\n  \"<|im_end|>\": 151645\n}\n",
)
