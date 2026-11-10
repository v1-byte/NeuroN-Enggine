# Catatan integrasi Flutter — 2026-11-10

## Implementasi pada snapshot ini

Flutter memanggil fitur Android melalui `MethodChannel('neuron/project')` dan `EventChannel('neuron/chat')`.

- **Model lokal:** halaman Model lokal memilih berkas `.gguf`; Kotlin menyalinnya ke folder `models` privat aplikasi, menyimpan path di project, dan mengubah mode ke `LOCAL`. Chat memakai `EngineHub` dan `LlamaCppEngine`. Jika native library tidak tersedia, UI memberi peringatan dan chat mengembalikan error yang berasal dari engine.
- **Server lokal:** halaman Server membuat key acak 256-bit, meminta konfirmasi HTTP, memvalidasi panjang minimum 32 karakter, lalu menyimpan port/key melalui `ServerPrefs`/`SecretStore` dan mengontrol `LocalServerService`. Listener dibatasi pada satu IPv4 aktif (atau loopback bila tidak ada); tetap HTTP tanpa TLS.
- **RAG:** halaman Data & RAG mengimpor file pilihan ke folder knowledge privat, menambahkannya ke `KnowledgeConfig`, membangun indeks SQLite lewat engine terpilih, dan menambahkan konteks hasil retrieval ke pesan pengguna terakhir pada chat.
- **Hugging Face:** halaman Hugging Face mencari repo bertag GGUF, menampilkan berkas GGUF, mengunduh file yang dipilih melalui `HfClient`, memeriksa checksum bila Hub menyediakan checksum, dan mengatur file hasil sebagai model lokal terpilih. Token HF disimpan melalui `HfPrefs`.
- **Copilot:** layar Flutter meminta saran, menampilkan nilai sebelum dan usulan per file, lalu mewajibkan checkbox review sebelum apply. Eval sebelum/sesudah dan undo/reject lanjutan belum tersedia.
- **Pelatihan:** halaman Training masih placeholder; modul backend Kotlin/Python tidak serta-merta menyediakan workflow pengguna.

## Batasan yang masih ada

1. **Native inference belum siap hanya dengan memilih GGUF.** `libneuron_llama.so` harus dibangun dan disertakan untuk ABI/arsitektur Android target. Build native memerlukan NDK, CMake, dan sumber llama.cpp yang kompatibel.
2. **HF download menggunakan WorkManager background job.** UI menampilkan progres per-byte dan tombol pembatalan; tetap uji resume, notifikasi, dan lifecycle pada perangkat nyata.
3. **RAG memakai embedding engine yang sedang dipilih.** Endpoint API harus mendukung `/v1/embeddings`; model lokal harus dapat menghasilkan embedding. Progress indexing dan penghapusan satu dokumen belum disediakan.
4. **RAG tidak otomatis membuat embedding model khusus.** Konfigurasi yang dipakai adalah engine aktif; kegagalan endpoint embedding akan ditampilkan kepada pengguna.
5. **Server mengakses model/proyek default yang sama.** Inbound HTTP tidak mengenkripsi key/prompt; uji interface, port, notifikasi foreground service, perilaku Android 14+, dan koneksi klien. Jangan gunakan pada jaringan publik atau forward port ke internet. Release menolak HTTP outbound; gunakan HTTPS untuk API engine eksternal.
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
