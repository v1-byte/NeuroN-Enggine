# Catatan integrasi Flutter — 2026-11-10

## Implementasi pada snapshot ini

Flutter memanggil fitur Android melalui `MethodChannel('neuron/project')` dan `EventChannel('neuron/chat')`.

- **Model lokal:** halaman Model lokal memilih berkas `.gguf`; Kotlin menyalinnya ke folder `models` privat aplikasi, menyimpan path di project, dan mengubah mode ke `LOCAL`. Chat memakai `EngineHub` dan `LlamaCppEngine`. Jika native library tidak tersedia, UI memberi peringatan dan chat mengembalikan error yang berasal dari engine.
- **Server lokal:** halaman Server menyimpan port dan API key melalui `ServerPrefs`/`SecretStore`, lalu memulai atau menghentikan `LocalServerService` dan membaca status service.
- **RAG:** halaman Data & RAG mengimpor file pilihan ke folder knowledge privat, menambahkannya ke `KnowledgeConfig`, membangun indeks SQLite lewat engine terpilih, dan menambahkan konteks hasil retrieval ke pesan pengguna terakhir pada chat.
- **Hugging Face:** halaman Hugging Face mencari repo bertag GGUF, menampilkan berkas GGUF, mengunduh file yang dipilih melalui `HfClient`, memeriksa checksum bila Hub menyediakan checksum, dan mengatur file hasil sebagai model lokal terpilih. Token HF disimpan melalui `HfPrefs`.
- **Pelatihan/Copilot:** halaman sekarang menjelaskan dengan terang bahwa UI Flutter belum terhubung ke `RemoteTrainer` maupun `CopilotAgent`. Modul Kotlin yang sudah ada tidak serta-merta mengaktifkan workflow UI tersebut.

## Batasan yang masih ada

1. **Native inference belum siap hanya dengan memilih GGUF.** `libneuron_llama.so` harus dibangun dan disertakan untuk ABI/arsitektur Android target. Build native memerlukan NDK, CMake, dan sumber llama.cpp yang kompatibel.
2. **HF download belum menjadi background job Flutter.** Layar tidak menampilkan progres per-byte atau tombol pembatalan. Unduhan berjalan pada worker method-call dan baru melaporkan selesai/gagal setelah method kembali.
3. **RAG memakai embedding engine yang sedang dipilih.** Endpoint API harus mendukung `/v1/embeddings`; model lokal harus dapat menghasilkan embedding. Progress indexing dan penghapusan satu dokumen belum disediakan.
4. **RAG tidak otomatis membuat embedding model khusus.** Konfigurasi yang dipakai adalah engine aktif; kegagalan endpoint embedding akan ditampilkan kepada pengguna.
5. **Server mengakses model/proyek default yang sama.** Uji port, API key, notifikasi foreground service, perilaku Android 14+, dan koneksi klien jaringan sebelum digunakan di luar perangkat tepercaya. HTTP tidak mengenkripsi lalu lintas.
6. **Belum ada hasil build/test Android pada snapshot ini.** Perintah gagal karena Flutter SDK tidak terpasang (`/home/ubuntu/sdk/flutter/...` tidak ditemukan) dan Android SDK tidak tersedia (`ANDROID_HOME`/`sdk.dir` belum ditetapkan). Karena itu perubahan Kotlin/Dart perlu diverifikasi di mesin developer dengan Flutter stable, Android SDK, JDK 17, dan NDK untuk native.

## Pemeriksaan yang perlu dijalankan pada mesin Android

```bash
cd flutter_app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
cd android
./gradlew :app:compileDebugKotlin
```

Setelah build debug lulus: uji chat API, pilih model GGUF kecil yang sesuai RAM, start/stop server lalu panggil `/health` dan `/v1/models` dari klien, impor PDF/DOCX/TXT dan indeks RAG, lalu cari dan unduh file GGUF HF. Uji pelatihan dan Copilot belum dapat dilakukan melalui UI Flutter sampai workflow tersebut dibuat.
