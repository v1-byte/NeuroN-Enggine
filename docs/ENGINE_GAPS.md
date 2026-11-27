# Celah engine yang diketahui

Cakupan: modul `:engine` (Kotlin + JNI llama.cpp) dan titik pakainya di `:rag`, `:copilot`, serta UI Flutter (`flutter_app/`).
Status verifikasi: **tidak ada yang dikompilasi atau dijalankan** di lingkungan penulisan dokumen ini (tanpa Kotlin/Gradle/NDK/Flutter).

> **Catatan (2026-11-27):** dokumen ini ditulis ulang. Versi lama menyebut `RemoteApiEngine`, `LocalServer`, dan modul `:server`,
> yang sudah dihapus pada 2026-11-24 (engine kini hanya llama.cpp lokal). Entri yang hanya relevan untuk modul itu dibuang.

## Sudah tertangani di kode
| Masalah | Keadaan sekarang | Lokasi |
|---|---|---|
| Template chat tak dikenali jatuh diam-diam ke ChatML | Tidak lagi diam: saat load engine menguji template dan mengirim peringatan ke UI (`EngineWarnings`); peringatan juga dikirim saat fallback dipakai | `LlamaCppEngine.kt` (`templateWarning`), `EngineWarnings.kt` |
| Statistik token / kecepatan | `GenStats` + `lastStats` (hitung token + waktu) | `InferenceEngine.kt`, `LlamaCppEngine.kt` |
| Tes unit engine | Ada: Guardrails, Calculator, Text, ToolEngine, HistoryLimiter, ModelDefaults, EnginePreflight, EngineErrors, GgufMeta, LoraAdapter, PrivacyPolicy | `engine/src/test` |

Yang **belum** tertangani untuk template: model dengan template Jinja khusus tetap dijawab memakai ChatML (hanya diberi peringatan).

## Masih kurang (urut prioritas)
1. **Kompilasi + uji di perangkat.** Semua fase berstatus "BELUM dikompilasi". Risiko terbesar: API llama.cpp (ada lapisan `llama_compat.h`), JNI, dan sync Gradle pertama. Source llama.cpp tidak ikut di zip; jalankan `scripts/setup_native.sh --tag <tag>` dulu.
2. **Template chat Jinja bebas.** Solusi: interpreter Jinja minimal (for/if/`message['role']`/`bos_token`/`add_generation_prompt`), atau minja (header-only, ikut `common/` llama.cpp) lewat JNI. Sementara itu hanya ada peringatan.
3. **Embedding lokal lambat.** `nativeEmbed` membuat dan membuang `llama_context` di setiap panggilan. Untuk RAG (ratusan chunk) ini mahal. Solusi: cache context embedding per Handle dan dukung batch beberapa teks per panggilan. Perlu dikompilasi terhadap llama.cpp terkunci; sengaja belum diubah tanpa bisa membangun.
4. **Jumlah token prompt lokal tidak dilaporkan** (`promptTokens=0`). `nativeGenerate` perlu mengembalikan `n_prompt_tokens` dan `n_reused` (prefix cache).
5. **Tool calling format OpenAI** (`tools` / `tool_calls`) belum ada; saat ini berbasis prompt `<tool_call>`.
6. **Vision lokal** (mmproj / libmtmd) belum ada; mode LOCAL menolak gambar.
7. **Sampler terbatas.** Belum ada: grammar/JSON mode (GBNF), mirostat, jendela penalti dapat diatur (hardcode 64), `n_probs`/logprobs, `typical_p`, DRY.
8. **Format selain GGUF** (ONNX, AWQ/GPTQ) ditolak dengan pesan konversi (`runnableOnDevice` + `conversionHint`).
9. **Satu engine, satu generate sekaligus** (`EngineHub.gate`); tidak ada antrean berprioritas atau continuous batching.
10. **Guardrail output** memakai jendela 64 karakter; pola yang lebih panjang bisa sebagian tampil.
11. **Tes instrumentasi** (JNI di perangkat) belum ada.
12. **Training ON_DEVICE**: `libllamafinetune.so` tidak ada di repo; flag CLI dan format log belum diverifikasi (lihat [ON_DEVICE.md](ON_DEVICE.md)).

## Cara memverifikasi
```
./scripts/setup_native.sh --tag <tag>            # sekali, untuk build native
./gradlew :engine:testDebugUnitTest :project:testDebugUnitTest :copilot:testDebugUnitTest
./gradlew :engine:assembleDebug -PwithNative
cd flutter_app && flutter analyze && flutter test && flutter build apk --debug
```
Bila ada tes gagal karena salah hitung ekspektasi (bukan salah kode), perbaiki ekspektasinya; nilai tes banyak dihitung manual.
