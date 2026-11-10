# Checklist verifikasi NeuroN Engine

Dokumen ini membedakan implementasi kode, verifikasi yang dapat dijalankan di CI, dan verifikasi yang membutuhkan perangkat Android fisik.

## Verifikasi otomatis

- `flutter analyze` dan `flutter test` dijalankan oleh workflow `.github/workflows/android.yml`.
- `./gradlew testDebugUnitTest :server:compileDebugKotlin --no-daemon` dijalankan oleh workflow.
- `flutter build apk --debug` dijalankan oleh workflow dan APK diunggah sebagai artifact.
- `python3 -S python/tests/smoke_server.py` memverifikasi server Python dalam mode stub; HTTP FastAPI nyata memerlukan `pip install -r python/requirements.txt`.

## Native llama.cpp

- `scripts/setup_native.sh` menyiapkan submodule llama.cpp.
- Build native harus dipanggil dengan `./gradlew :engine:assembleDebug -PwithNative` dari host Android yang memiliki NDK/CMake.
- Target yang didukung untuk inferensi lokal adalah `arm64-v8a`, model harus GGUF, dan Android minimum adalah API 26.
- Uji perangkat wajib mencakup: memuat GGUF kecil, mencatat RSS/heap saat load dan generate, menerima token streaming, membatalkan generate, dan memastikan unload tidak crash.
- Uji perangkat tidak dapat disimulasikan secara bermakna di runner Linux tanpa APK dan perangkat/emulator Android.

## API dan RAG

- Endpoint `/v1/embeddings` sudah memiliki kontrak OpenAI-compatible dan membutuhkan Bearer API key.
- Indexing RAG menggunakan endpoint embedding engine yang aktif; API yang dipakai harus mengembalikan `data[].embedding` non-kosong.
- Uji integrasi: `POST /v1/embeddings` dengan satu string, daftar string, key salah, input kosong, dan model yang belum siap.

## Server lokal Android

- Start/stop memakai `LocalServerService` foreground dengan `specialUse`, wake lock, Wi-Fi lock, dan notifikasi Stop.
- API key wajib minimal 8 karakter dan disimpan melalui `SecretStore`.
- Server bind ke `0.0.0.0` untuk akses LAN; gunakan hanya di jaringan tepercaya karena HTTP tidak terenkripsi.
- Uji perangkat: start/stop, `/health`, `/v1/models`, `/v1/chat/completions` streaming/non-stream, `/v1/embeddings`, key salah, Android 14+, dan restart service.

## Fitur UI yang sebelumnya tertunda

- Unduhan Hugging Face sekarang memakai WorkManager foreground job, progress byte-level (`done`/`total`), resume, dan cancel dari UI Flutter.
- Copilot sekarang memiliki bridge Flutter/Kotlin untuk meminta saran, menampilkan patch per file, dan menerapkan patch setelah ditinjau. Uji provider/model nyata dan evaluasi kualitas saran tetap memerlukan perangkat/endpoint yang dikonfigurasi.
- Pelatihan masih memiliki modul Kotlin backend, tetapi orkestrasi dataset, konfigurasi job, progres, pembatalan, dan pengambilan adapter dari UI Flutter belum selesai.
- Binary `libllamafinetune.so` dan flag CLI training on-device belum disertakan; ON_DEVICE tetap tidak boleh dinyatakan siap produksi.
