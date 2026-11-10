# Tool calling & Guardrails (features/features.json)

Keduanya dipasang lewat `EngineFactory.wrap(engine, project)`, jadi berlaku untuk engine lokal maupun API.
Chat di app sudah memakainya. Untuk server lokal, bungkus engine sebelum diberikan ke `LocalServer`.

## Contoh features/features.json
```json
{
  "tools": [
    {"name": "current_time", "description": "Get the current local date and time.", "parametersJsonSchema": "{\"type\":\"object\",\"properties\":{}}"},
    {"name": "calculate", "description": "Evaluate an arithmetic expression. Supports + - * / % ^ and parentheses.",
     "parametersJsonSchema": "{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"}},\"required\":[\"expression\"]}"}
  ],
  "guardrailBlockedWords": ["kata_terlarang"],
  "guardrailRegex": ["\\b\\d{16}\\b"]
}
```

## Tool calling
- Berbasis prompt: model membalas `<tool_call>{"name":..,"arguments":{..}}</tool_call>`, app menjalankan tool, mengirim hasil sebagai
  pesan `<tool_response>`, lalu model menjawab. Maksimal 4 putaran per pesan. Di chat muncul baris `⚙ nama(args)`.
- Hanya tool yang terdaftar di `tools` yang boleh dipanggil. Implementasi bawaan (`BuiltinTools`): `current_time`, `calculate`
  (tanpa akses file/jaringan). Tool lain butuh `ToolExecutor` sendiri (mis. cari dokumen RAG, buka URL) dan diberikan ke `wrap(..., exec = ...)`.
- Kualitas bergantung model: Qwen2.5-Instruct / Llama 3.x cukup andal; model <3B sering salah format JSON.
- Panggilan yang rusak dikembalikan ke model sebagai `Error: ...` supaya bisa memperbaiki dirinya.

## Guardrails
- Input: teks asli pengguna dicek sebelum model dimuat; jika cocok, model tidak dipanggil sama sekali.
- Output: dicek saat streaming dengan menahan ~64 karakter terakhir; jika cocok, output dihentikan dan diganti pesan pemberitahuan.
- Kata terlarang tidak membedakan huruf besar/kecil; regex harus valid (divalidasi saat Simpan).
- Pola regex yang melebihi ~64 karakter bisa sebagian sudah tampil sebelum terdeteksi. Guardrail ini penyaring sederhana, bukan jaminan keamanan.
- Belum diuji / dikompilasi di perangkat.
