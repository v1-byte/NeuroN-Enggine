# Analisis engine: apa yang kurang

Cakupan: modul `:engine` (Kotlin + JNI llama.cpp) dan titik pakainya di `:server`, `:rag`, `:copilot`, serta UI Flutter (`flutter_app/`, dulu modul Compose `:app`).
Status verifikasi: **tidak ada yang dikompilasi** (sandbox tanpa Kotlin/Gradle/NDK). Lihat bagian "Cara memverifikasi".

## Sudah dikerjakan (batch ini)
| # | Masalah | Perbaikan | File |
|---|---|---|---|
| 1 | `RemoteApiEngine.embed` memanggil `execute()` (blocking) tanpa dispatcher. Dipanggil dari ViewModel/RAG di main thread akan `NetworkOnMainThreadException`; juga tidak bisa dibatalkan | `withContext(Dispatchers.IO)` + `call.cancel()` saat coroutine dibatalkan; pesan error memuat isi body; cek `data` kosong | RemoteApiEngine.kt |
| 2 | Delta `"content": null` dari beberapa server (vLLM, tool-call chunk) tercetak sebagai teks `null` karena `optString` di org.json mengubah JSON null menjadi string "null" | cek `isNull("content")` dulu | RemoteApiEngine.kt |
| 3 | Error di tengah stream SSE (`{"error":{...}}`) diabaikan, chat berhenti diam-diam | dilempar sebagai `IOException` | RemoteApiEngine.kt |
| 4 | Tidak ada statistik token / kecepatan; server belum mengisi `usage` | `GenStats` + `InferenceEngine.lastStats` (API: dari `usage`, fallback hitung chunk; lokal: hitung token + waktu). `stream_options.include_usage` dikirim | InferenceEngine.kt, RemoteApiEngine.kt, LlamaCppEngine.kt |
| 5 | `/v1/chat/completions` non-stream selalu `finish_reason:"stop"` dan tanpa `usage` | `usage` terisi; `"length"` bila token = max_tokens | LocalServer.kt |
| 6 | Connect timeout tidak diatur (default 10 dtk, tidak eksplisit) | 20 dtk eksplisit | RemoteApiEngine.kt |
| 7 | **Nol tes** untuk engine | 4 berkas JUnit: Utf8Stream, StopMatcher, Calculator, Guardrails, ToolEngine (loop, tool tak dikenal, JSON rusak, batas putaran) + `testImplementation(junit)` | engine/src/test, engine/build.gradle.kts |

## Masih kurang (urut prioritas), belum dikerjakan
1. **Kompilasi + uji di perangkat.** Semua fase berstatus "BELUM dikompilasi". Risiko terbesar: API llama.cpp (sudah ada lapisan `llama_compat.h`), JNI, dan sync Gradle pertama.
2. **Template chat Jinja bebas.** `model/chat_template.jinja` yang tidak dikenali `llama_chat_apply_template` jatuh diam-diam ke ChatML (hanya `Log.w`). Model dengan template khusus akan menjawab buruk tanpa pesan jelas ke pengguna. Solusi: interpreter Jinja minimal (for/if/`message['role']`/`bos_token`/`add_generation_prompt`), atau gunakan minja (header-only, ikut llama.cpp `common/`) lewat JNI. Sementara itu minimal tampilkan peringatan di UI saat jatuh ke ChatML.
3. **Embedding lokal lambat.** `nativeEmbed` membuat dan membuang `llama_context` di setiap panggilan. Untuk RAG (ratusan chunk) ini mahal. Solusi: cache context embedding per Handle, dan dukung batch beberapa teks per panggilan.
4. **Jumlah token prompt lokal tidak dilaporkan** (`promptTokens=0`). Perlu `nativeGenerate` mengembalikan `n_prompt_tokens` dan `n_reused` (prefix cache) supaya `usage` lengkap.
5. **Tool calling format OpenAI** (`tools` / `tool_calls` di server) belum ada; saat ini hanya berbasis prompt `<tool_call>`. Klien OpenAI standar tidak bisa memakainya lewat server lokal.
6. **Vision lokal** (mmproj / libmtmd) belum ada; mode LOCAL menolak gambar.
7. **Sampler terbatas.** Belum ada: grammar/JSON mode (GBNF), mirostat, jendela penalti dapat diatur (hardcode 64), `n_probs`/logprobs, `typical_p`, DRY.
8. **Format selain GGUF**: ONNX (onnxruntime-genai), AWQ/GPTQ langsung. Saat ini ditolak dengan pesan konversi.
9. **Satu engine, satu generate sekaligus** (`EngineHub.gate`). Tidak ada antrean dengan prioritas/pembatalan oleh klien server selain putus koneksi, dan tidak ada continuous batching.
10. **Pengamanan**: token HF & API key tersimpan plaintext di SharedPreferences (catatan di STATUS). Guardrail output memakai jendela 64 karakter; pola lebih panjang bisa sebagian tampil.
11. **Tes instrumentasi** (JNI di perangkat) dan tes `RemoteApiEngine` dengan MockWebServer (butuh org.json asli: `testImplementation("org.json:json:...")`).

## Cara memverifikasi batch ini
```
./gradlew :engine:testDebugUnitTest       # 4 kelas tes, tanpa native
./gradlew :engine:compileDebugKotlin :server:compileDebugKotlin   # memeriksa kompilasi RemoteApiEngine/LocalServer
cd flutter_app && flutter build apk --debug                        # memeriksa UI Flutter
```
Jika ada tes gagal karena salah hitung ekspektasi (bukan salah kode), perbaiki ekspektasinya; nilai tes dihitung manual, belum dijalankan.

## Catatan editor
Editor kini punya nomor baris, highlight JSON, undo/redo, cari-ganti, dan Rapikan (lihat STATUS.md). Sisa: auto-indent, scroll ke kursor, tab file, buat/hapus file, viewer berhalaman untuk file besar.
