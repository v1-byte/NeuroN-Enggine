# Urutan Pengerjaan (ikuti berurutan; tiap fase menghasilkan APK yang bisa dites)

> **Catatan migrasi (2026-11-09):** UI sekarang ditulis di Flutter (`flutter_app/`). Langkah yang menyebut layar atau Compose berarti UI Flutter yang harus dibuat ulang. Lihat [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).

## Fase 0 - Pondasi (1 minggu)
1. Buka `flutter_app/` dan pastikan `flutter build apk --debug` jalan. Modul Kotlin: `./gradlew :model:assembleDebug`.
2. Modul `:model` (semua data class config) + `:project` (simpan/muat project.json, VirtualTree).
3. UI `Workbench` (Flutter): Explorer + editor teks + simpan. Belum ada AI. Validasi JSON. Sudah ada: editor JSON dan validasi; Explorer penuh belum.

## Fase 1 - Engine AI (inti, 2-3 minggu)
4. `:engine` interface `InferenceEngine` (sudah ada).
5. `RemoteApiEngine` dulu (paling cepat jalan): chat ke OpenAI-compatible API. Tes chat di panel bawah.
6. Native llama.cpp: tambah submodule, isi `llama_jni.cpp`, `LlamaCppEngine` (GGUF). Streaming token + tombol stop.
7. Hubungkan parameter chat + hardware ke sampler/context. Chat template + stop sequence.

## Fase 2 - Hugging Face (1 minggu)
8. `HfClient.search` + layar pencarian (filter gguf / onnx / text-generation, sort downloads).
9. Unduh dengan resume + progress, WorkManager, cek ruang penyimpanan. Token HF untuk model gated.
10. Opsi "unduh semua file repo".

## Fase 3 - Server lokal (1 minggu)
11. `LocalServer` (Ktor) OpenAI-compatible + API key + SSE streaming.
12. `LocalServerService` foreground + notifikasi + tampil IP:port/QR.
13. Tes dari laptop: `curl http://IP_HP:8080/v1/chat/completions`.

## Fase 4 - Copilot (1 minggu)
14. `CopilotAgent` memakai engine API (atau lokal). Tampilan diff + terima/tolak patch.
15. Eval sederhana: kumpulan prompt uji, bandingkan sebelum/sesudah edit.

## Fase 5 - RAG (1-2 minggu)
16. Parser file (txt/md/pdf), chunking, embedding (model GGUF embedding via engine), VectorStore SQLite.
17. Sisipkan konteks ke prompt; tampilkan sumber.

## Fase 6 - Dataset & Training (2-4 minggu)
18. Import dataset dari file (picker SAF), validasi, preview, split train/val.
19. Trainer REMOTE: server Python di `python/` (PEFT/TRL: LoRA, QLoRA, DPO) + `RemoteTrainer` Kotlin. [KERANGKA SUDAH ADA] Tinggal UI: pilih dataset, tombol Latih, grafik loss, unduh adapter .gguf.
20. Trainer ON_DEVICE (LoRA model kecil via llama.cpp finetune). Muat adapter ke engine.

## Fase 7 - Fitur lanjutan
21. Tools/function calling, Guardrails (regex/kata terlarang).
22. Vision (mmproj llama.cpp), TTS (Android TextToSpeech), STT (SpeechRecognizer / whisper.cpp).
23. Konversi format: Safetensors/AWQ/GPTQ -> GGUF lewat server konversi (tidak bisa di HP). ONNX via onnxruntime-genai.
24. Rilis: ProGuard, ABI arm64 saja, uji perangkat RAM 6/8/12 GB.
