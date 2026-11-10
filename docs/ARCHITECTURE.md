# Arsitektur

Sejak migrasi 2026-11-09, UI Android ditulis di Flutter. Engine, konfigurasi, RAG, server, dan trainer tetap berupa modul Kotlin library dan server Python. Detail migrasi: [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).

```
flutter_app/  (UI Flutter; entry point APK com.neuron.engine)
   lib/main.dart  : editor JSON, inspektur, panel chat/log/copilot, dialog
                    (saat ini MODE SIMULASI, belum memanggil modul di bawah)
   android/app/  : host Android (FlutterActivity, manifest, ikon, Gradle)
        |
        |  rencana: jalur A (MethodChannel ke Kotlin) atau B (HTTP ke LocalServer loopback)
        v
modul Kotlin library  (root Gradle; belum masuk APK)
   |-- model    : data class config (AiProject, ChatParams, ModelFiles, ...), validasi, SecretStore
   |-- project  : AiProject <-> file virtual (VirtualTree), simpan/muat project.json
   |-- hf       : cari & unduh model Hugging Face (WorkManager, resume, SHA-256)
   |-- engine   : InferenceEngine { LlamaCppEngine (JNI) | RemoteApiEngine (HTTP OpenAI-compatible) }
   |-- rag      : Chunker, FileParser, vector store, RagPipeline; memakai engine untuk embedding
   |-- train    : Dataset, Trainer { REMOTE | ON_DEVICE }, ModelOpsClient
   |-- server   : Ktor OpenAI-compatible + LocalServerService (foreground), memanggil engine
   `-- copilot  : memakai engine mana pun untuk menambal AiProject, plus Eval dan cek konsistensi

python/  (NeuroN Trainer, FastAPI) di PC/server: dataset, training LoRA/QLoRA/DPO, konversi GGUF,
         operasi model. Dipanggil dari APK lewat HTTP. Python TIDAK berjalan di dalam APK.
```

## Aturan

- Semua pemanggilan AI lewat `InferenceEngine`. UI, server, RAG, dan copilot tidak tahu engine mana yang dipakai.
- Konfigurasi disimpan sebagai file project dengan 7 bagian (lihat `README.md` di root). Setiap bagian dibaca dan ditulis lewat `VirtualTree.read` / `VirtualTree.write`, dan `write` memvalidasi isi sebelum disimpan.
- Parameter generate diatur lewat `engine/ModelDefaults.kt`: `chat/params.json` yang sudah diubah > `model/Modelfile` > `model/generation_config.json` > bawaan.
- UI Flutter hanya boleh bicara ke modul Kotlin lewat satu lapisan jembatan (jalur A atau B), supaya kontrak `InferenceEngine` tetap satu-satunya titik pemanggilan AI.
