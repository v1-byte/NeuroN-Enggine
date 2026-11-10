# Catatan integrasi Flutter — 2026-11-10

## Implementasi pada snapshot ini

Flutter memanggil fitur Android melalui `MethodChannel('neuron/project')` dan `EventChannel('neuron/chat')`.

- **Model lokal:** halaman Model lokal memilih berkas `.gguf`; Kotlin menyalinnya ke folder `models` privat aplikasi, menyimpan path di project, mengubah mode ke `LOCAL`, dan menyediakan daftar model dengan ukuran/status aktif. Model dari Download maupun hasil HF dapat diaktifkan ulang tanpa memilih file lagi.
- **Server lokal:** halaman Server membuat key acak 256-bit, meminta konfirmasi HTTP, memvalidasi panjang minimum 32 karakter, lalu menyimpan port/key melalui `ServerPrefs`/`SecretStore` dan mengontrol `LocalServerService`. Listener dibatasi pada satu IPv4 aktif (atau loopback bila tidak ada); tetap HTTP tanpa TLS.
- **RAG:** halaman Data & RAG mengimpor file pilihan ke folder knowledge privat, menambahkannya ke `KnowledgeConfig`, membangun indeks SQLite lewat engine terpilih, dan menambahkan konteks hasil retrieval ke pesan pengguna terakhir pada chat.
- **Hugging Face:** halaman Hugging Face mencari repo bertag GGUF, menampilkan ukuran berkas dari detail/tree API, memakai accordion repository agar daftar file muncul di tempat yang sama, mengunduh file melalui segmented HTTP Range hingga delapan koneksi untuk GGUF besar, memeriksa checksum bila Hub menyediakan checksum, dan mengaktifkan file hasil sebagai model lokal. Kecepatan aktual tetap bergantung pada bandwidth/CDN; faktor 30x tidak dapat dijamin.
- **Copilot:** layar Flutter meminta saran, menampilkan nilai sebelum dan usulan per file, lalu mewajibkan checkbox review sebelum apply. Eval sebelum/sesudah dan undo/reject lanjutan belum tersedia.
- **Pelatihan:** layar Training mengimpor dan memvalidasi dataset JSONL/JSON/CSV, memilih model dari daftar lokal atau mengimpor GGUF eksternal, menyimpan URL/model/parameter remote, memulai job dan polling progres/log, membatalkan/menyambung job, serta mengunduh ZIP atau LoRA GGUF. Jika model dasar adalah file lokal, `TrainingBridge` mengunggahnya ke endpoint trainer `/models` sebelum job. API key trainer disimpan melalui `SecretStore`; file konfigurasi proyek hanya menyimpan field key kosong. Split train/val, grafik loss dan training on-device belum tersedia. Build/perangkat/server belum diuji.
- **Tema/tutorial/animasi:** `theme.dart` menyediakan lima preset warna; `tutorial.dart` menyediakan tutorial modal bertahap; `AnimatedSwitcher` memberi transisi fade/slide pada navigasi.
- **Auto-update:** `UpdateBridge` membaca GitHub Releases terbaru, membandingkan tag semver, mengunduh asset APK setelah konfirmasi, lalu membuka Android Package Installer melalui `FileProvider`. Android tetap meminta persetujuan instalasi.

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
