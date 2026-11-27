package com.neuron.engine

import com.neuron.model.ToolDef
import com.neuron.model.ChatParams
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

interface ToolExecutor { suspend fun call(name: String, argsJson: String): String }

/**
 * Tool calling berbasis prompt (jalan di model GGUF apa pun, tidak butuh dukungan khusus):
 * model diminta membalas <tool_call>{"name":..,"arguments":{..}}</tool_call>; hasilnya dikirim balik sebagai pesan
 * <tool_response> lalu model menjawab. Hanya tool yang terdaftar di features.tools yang boleh dipanggil.
 * Model kecil (<3B) sering salah format; Qwen2.5-Instruct / Llama 3.x lebih andal.
 */
class ToolEngine(
    private val inner: InferenceEngine,
    private val tools: List<ToolDef>,
    private val exec: ToolExecutor,
    private val maxSteps: Int = 4,
) : InferenceEngine by inner {
    private companion object { const val TAG = "<tool_call>"; const val END = "</tool_call>" }

    private fun toolPrompt() = buildString {
        append("You can call tools. Available tools:\n")
        tools.forEach { append("- ${it.name}: ${it.description}\n  parameters (JSON schema): ${it.parametersJsonSchema}\n") }
        append("To call a tool, reply with ONLY this and nothing else: $TAG{\"name\": \"<tool name>\", \"arguments\": {...}}$END\n")
        append("The result will come back in a <tool_response> message; then answer the user. If no tool is needed, just answer normally.")
    }

    override fun chat(messages: List<ChatMessage>, params: ChatParams): Flow<String> = flow {
        val withTools = params.copy(systemPrompt = params.systemPrompt + "\n\n" + toolPrompt(), stopSequences = params.stopSequences + END)
        val msgs = messages.toMutableList()
        for (step in 0..maxSteps) {
            val allowTools = step < maxSteps
            val sb = StringBuilder()
            var decided = false; var isCall = false
            inner.chat(msgs, if (allowTools) withTools else params).collect { tok ->
                sb.append(tok)
                if (!decided) {
                    val t = sb.toString().trimStart()
                    if (t.length >= TAG.length || !TAG.startsWith(t)) {
                        decided = true; isCall = allowTools && t.startsWith(TAG)
                        if (!isCall) emit(sb.toString())
                    }
                } else if (!isCall) emit(tok)
            }
            if (!decided) { emit(sb.toString()); return@flow }   // jawaban sangat pendek
            if (!isCall) return@flow

            val body = sb.toString().substringAfter(TAG).substringBefore(END).trim()
            val (name, args, parseErr) = parse(body)
            emit("\n⚙ " + (if (parseErr == null) "$name($args)" else "panggilan alat tidak valid") + "\n")
            val result = when {
                parseErr != null -> "Error: $parseErr"
                tools.none { it.name == name } -> "Error: unknown tool '$name'. Available: ${tools.joinToString { it.name }}"
                else -> try { exec.call(name, args) } catch (e: CancellationException) { throw e } catch (e: Throwable) { "Error: ${e.message}" }
            }
            msgs += ChatMessage("assistant", "$TAG$body$END")
            msgs += ChatMessage("user", "<tool_response>\n${result.take(4000)}\n</tool_response>")
        }
    }

    private fun parse(body: String): Triple<String, String, String?> {
        return try {
            val o = Json.parseToJsonElement(body).jsonObject
            val name = o["name"]?.jsonPrimitive?.content ?: return Triple("", "{}", "missing \"name\"")
            val a = o["arguments"] ?: o["parameters"]
            val args = when {
                a == null -> "{}"
                a is JsonPrimitive -> if (a.isString) a.content else a.toString()   // gaya OpenAI: arguments berupa string JSON
                else -> a.toString()
            }
            Triple(name, args, null)
        } catch (e: Exception) { Triple("", "{}", "invalid JSON in tool call") }
    }
}

/** Tool bawaan yang aman (tanpa akses file/jaringan). Daftarkan di features/features.json agar bisa dipanggil. */
object BuiltinTools : ToolExecutor {
    val defs = listOf(
        ToolDef("current_time", "Get the current local date and time.", """{"type":"object","properties":{}}"""),
        ToolDef("calculate", "Evaluate an arithmetic expression. Supports + - * / % ^ and parentheses.",
            """{"type":"object","properties":{"expression":{"type":"string"}},"required":["expression"]}"""),
    )

    override suspend fun call(name: String, argsJson: String): String = when (name) {
        "current_time" -> java.time.ZonedDateTime.now().format(java.time.format.DateTimeFormatter.ISO_OFFSET_DATE_TIME)
        "calculate" -> {
            val expr = Json.parseToJsonElement(argsJson).jsonObject["expression"]?.jsonPrimitive?.content ?: error("expression is required")
            val v = Calculator.eval(expr)
            if (v == Math.rint(v) && Math.abs(v) < 1e15) v.toLong().toString() else v.toString()
        }
        else -> error("Tool '$name' tidak punya implementasi di app")
    }
}

/** Evaluator aritmetika: expr -> term (+|-)..., term -> unary (*|/|%)..., unary -> -unary | pow, pow -> primary (^ unary)? */
object Calculator {
    fun eval(src: String): Double {
        val p = P(src.filter { !it.isWhitespace() })
        val v = p.expr()
        require(p.i == p.s.length) { "Unexpected '${p.s[p.i]}' at ${p.i}" }
        require(!v.isNaN() && !v.isInfinite()) { "Math error (division by zero?)" }
        return v
    }

    private class P(val s: String) {
        var i = 0
        private fun peek(): Char? = if (i < s.length) s[i] else null
        fun expr(): Double {
            var v = term()
            while (peek() == '+' || peek() == '-') { val op = s[i++]; val r = term(); v = if (op == '+') v + r else v - r }
            return v
        }
        private fun term(): Double {
            var v = unary()
            while (peek() == '*' || peek() == '/' || peek() == '%') {
                val op = s[i++]; val r = unary()
                v = when (op) { '*' -> v * r; '/' -> v / r; else -> v % r }
            }
            return v
        }
        private fun unary(): Double = when (peek()) {
            '-' -> { i++; -unary() }
            '+' -> { i++; unary() }
            else -> pow()
        }
        private fun pow(): Double {
            val b = primary()
            if (peek() == '^') { i++; return Math.pow(b, unary()) }
            return b
        }
        private fun primary(): Double {
            val c = peek() ?: error("Unexpected end of expression")
            if (c == '(') {
                i++; val v = expr()
                require(peek() == ')') { "Missing ')'" }
                i++; return v
            }
            val start = i
            while (i < s.length && (s[i].isDigit() || s[i] == '.')) i++
            require(i > start) { "Unexpected '$c' at $start" }
            return s.substring(start, i).toDoubleOrNull() ?: error("Invalid number '${s.substring(start, i)}'")
        }
    }
}
