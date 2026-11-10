# Migrasi UI: Compose → Flutter

Tanggal: 2026-11-09. Dokumen ini berawal dari catatan migrasi dan beberapa bagian setelah ringkasan masih menggambarkan snapshot awal. **Ringkasan status aktual dan terbaru ada di bawah; jika ada konflik, gunakan ringkasan ini dan `STATUS.md`.**

## Status aktual setelah migrasi UI

- Flutter SDK dipakai untuk `flutter analyze` (lulus) dan `flutter test` (4 tes lulus). `flutter build apk --debug` belum dapat berjalan karena Android SDK tidak terpasang di lingkungan kerja.
- File proyek tetap memakai `ProjectRepository`/`VirtualTree`; pengaturan API dan API key melalui bridge yang ada, dengan key disimpan di `SecretStore`.
- Riwayat chat (tampilan dan konteks percakapan API) sekarang disimpan di SharedPreferences privat Android dan tombol hapus menghapus data tersimpan. Draft editor dipulihkan saat startup, di-flush ketika aplikasi masuk background, dan dibersihkan ketika proyek disimpan. Draft `engine/api.json` sengaja dikecualikan agar API key tidak tersimpan sebagai teks biasa.
- Modul `:model`, `:engine`, `:project`, `:rag`, `:server`, `:hf`, `:train`, dan `:copilot` telah dimasukkan ke Gradle Flutter. Flutter kini memanggil chat API/LOCAL, kontrol service server, impor dan indexing RAG, serta pencarian/unduh GGUF HF melalui platform bridge.
- Training remote tahap awal sudah terhubung: pilih/validasi dataset, simpan konfigurasi, mulai/stop/sambung job, lihat progres/log, unduh ZIP, atau unduh LoRA GGUF untuk dipakai. Belum mencakup split train/val, grafik loss, riwayat lintas server, atau ON_DEVICE; belum dikompilasi/diuji. Copilot dasar sudah aktif untuk meminta saran dan menerapkan patch setelah ditinjau. Native llama.cpp tetap memerlukan `.so` yang dibangun untuk ABI perangkat.
- APK dan tes Kotlin/Gradle belum diverifikasi di lingkungan perubahan ini karena Flutter/Android SDK tidak tersedia. Workflow publikasi release mewajibkan signing secrets valid dan memverifikasi signature APK sebelum upload.
- Build release menolak koneksi cleartext keluar; varian debug mengizinkan HTTP untuk pengujian. Server lokal masuk tetap HTTP, butuh konfirmasi pengguna, key acak minimal 32 karakter, dan hanya disarankan pada jaringan tepercaya.

## 1. Ringkasan

- UI Android pindah dari Compose ke **Flutter** di folder `flutter_app/`. Entry point APK sekarang proyek Flutter.
- Modul Compose `app/` dihapus. Layar UI-nya sudah tidak ada di repo sebelum migrasi (README lama menyebut "Layar UI sudah dihapus"; yang tersisa hanya `MainActivity` kosong). Dokumen `STATUS.md` lama masih menjelaskan layar-layar itu, jadi riwayatnya dipertahankan dan diberi catatan.
- Modul Kotlin library (`:model`, `:project`, `:hf`, `:engine`, `:rag`, `:train`, `:server`, `:copilot`) dan `python/` **tidak berubah**.
- Sumber UI: proyek `NeuraNFlutter` (prototipe dari HTML sumber). Integrasi Flutter saat ini menggunakan `MethodChannel`/`EventChannel` untuk fitur yang tercantum pada status aktual di atas.

## 2. Yang berpindah dan yang berubah

| Item | Sebelum | Sesudah |
|---|---|---|
| UI Android | Compose di modul `:app` (UI sudah dihapus, tinggal stub) | Flutter di `flutter_app/` |
| applicationId | `com.neuron.engine` (Kotlin), `com.neuran.engine` (Flutter) | `com.neuron.engine` |
| Nama aplikasi | "NeuroN Engine" (manifest Kotlin), "NeuraN Engine" (Flutter) | "NeuroN Engine", sesuai logo dan nama repo |
| Versi | `0.1.0` / versionCode 1 (Kotlin), `1.0.0+1` (Flutter) | `0.1.0+1` |
| Nama Dart package | `neurann_engine` | `neuron_engine` |
| Ikon aplikasi | belum ada | dibuat dari logo (mark "NE", ikon adaptif dengan latar putih) |
| Logo | — | Lihat bagian 4 |
| Gradle root | tanpa wrapper | wrapper Gradle 8.10.2 disalin dari `flutter_app/android` |
| Plugin Compose | ada di root | dihapus (tidak ada modul yang memakainya) |
| Permission | `INTERNET`, FGS, `WAKE_LOCK`, `POST_NOTIFICATIONS`, `RECORD_AUDIO` | sama, dipindah ke manifest Flutter |
| `usesCleartextTraffic`, `largeHeap` | aktif | release `false`; hanya debug overlay `true`; `largeHeap` tetap aktif |
| Signing rilis | `~/.gradle/gradle.properties` (`neuronKeystore`, dst.) | `flutter_app/android/key.properties` (format Flutter) |
| minify / R8 | aktif di release | **belum aktif** (lihat `docs/RELEASE.md` bagian 2) |
| `minSdk` | 26 | **26** (diset di `flutter_app/android/app/build.gradle`, sejak modul engine masuk APK) |
| ABI | `arm64-v8a` saja | semua ABI (default Flutter). Gunakan `--target-platform android-arm64` |
| Nama file APK | `NeuroN-Engine-<debug\|release>.apk` | `app-<debug\|release>.apk` dari Flutter, lalu diganti nama manual |
| ProGuard `app/proguard-rules.pro` | ada | dihapus. Aturan kotlinx dan WorkManager perlu dibuat ulang saat modul Kotlin masuk APK |

## 3. Peta fitur lama → status UI Flutter

Dokumen lama (`STATUS.md`, `ARCHITECTURE.md`, dan lain-lain) menjelaskan fitur dari UI Compose. Tabel ini menunjukkan status implementasi Flutter saat ini.

| Area | Status di Flutter | Catatan |
|---|---|---|
| Editor JSON (`params.json`, `config.json`) | **Sebagian** | Nomor baris, cari dan ganti (ganti semua), Rapikan, status `JSON valid`/`JSON error`. Hanya dua file tetap |
| Undo / redo | Tombol ada, **belum berfungsi** | Menampilkan "belum tersedia" |
| Highlight JSON, auto-indent | **Belum** | Switch auto-indent di Pengaturan belum berpengaruh |
| Tab file terbuka, buat/hapus file | **Belum** | Rename hanya mengubah nama tampilan |
| Explorer (13 tab VirtualTree) | **Belum** | Rail "Berkas" dan 7 bagian config tampil sebagai teks, belum membuka file |
| Inspektur parameter | **Ada** | Slider temperature, top-p, top-k, max tokens; seed; dropdown engine |
| Muat / simpan file JSON | **Ada** | Lewat file picker sistem. Belum membaca project sungguhan |
| Chat | **Terhubung (API/LOCAL)** | Lewat `NeuronBridge` dan `EngineHub`; mode lokal membutuhkan native library. RAG menambahkan konteks jika indeks aktif. Belum dikompilasi |
| Tool calling, guardrails | **Terhubung dasar** | Toggle tool calling dan simpan kata/pola guardrail tersedia; hasil tetap bergantung pada model dan bukan pengganti kontrol keamanan backend |
| Log | **Ada** | Teks sederhana. Diagnostik RAM/ABI belum ada |
| Copilot | **Terhubung dasar** | Flutter meminta saran dan menerapkan patch per file setelah ditinjau; flow evaluasi, undo/reject bertingkat belum tersedia |
| Perintah (command palette) | **Ada** | Dialog daftar perintah |
| 🤗 Model (Hugging Face) | **Terhubung (dasar)** | Cari model GGUF, daftar file, unduh dengan progress/cancel dan verifikasi bila checksum tersedia |
| 🖧 Server lokal | **Terhubung (dasar)** | Simpan port/key terenkripsi, buat key acak, konfirmasi risiko HTTP, mulai/hentikan service; tanpa TLS dan belum diuji di perangkat |
| 📚 Data / RAG | **Terhubung (dasar)** | Impor berkas, indeks SQLite dan retrieval konteks chat; progres/hapus berkas belum ada |
| 🏋 Latih (fine-tune) | **Terhubung dasar (remote)** | Dataset JSONL/JSON/CSV dapat dipilih dan divalidasi; konfigurasi remote, mulai/progres/log/stop/sambung, unduh ZIP dan LoRA GGUF tersedia. Belum ada split train/val atau grafik; ON_DEVICE belum tersedia; build/perangkat belum diverifikasi |
| Hardware (`hardware/engine.json`) | **Nilai tetap** | GPU layers 32, threads 8, dst. Tombol simpan hanya menampilkan pesan |
| Fitur (`features/features.json`) | **Switch saja** | Tools, Vision, TTS, STT, Guardrails. Tidak tersimpan |
| Pengaturan | **Statis** | Dialog teks + switch auto-indent |
| Vision, TTS, STT | **Belum tersedia di Flutter** | Backend lama memiliki sebagian kemampuan, tetapi UI Flutter saat ini belum menyediakan alur lampiran vision atau kontrol TTS/STT |
| Eval | **Belum** | |
| Engine lokal (llama.cpp) | **Tersambung bersyarat** | File GGUF bisa dipilih/disalin dan mode LOCAL dipakai; perlu binary JNI yang sesuai ABI |
| Engine API (`RemoteApiEngine`) | **Terhubung** | Base URL, model, dan API key di Pengaturan. API key di SecretStore (terenkripsi). Belum dikompilasi |

## 4. Aset logo (dikompres)

Sumber: `5afe8227-image.png` (1600×1600 RGBA, 415 KB, mayoritas transparan). Dibuat ulang dengan `scripts/make_brand_assets.py`.

| Berkas | Ukuran | Dipakai untuk |
|---|---|---|
| `branding/neuron_logo.png` (640 px, palet 256 warna dengan alpha) | 20 KB | Dokumentasi dan README. Tidak masuk APK |
| `flutter_app/assets/images/neuron_mark.png` (256 px) | 5 KB | Header UI (masuk APK) |
| `flutter_app/android/app/src/main/res/mipmap-*/ic_launcher.png` (48–192 px, latar putih) | ~28 KB | Ikon launcher untuk Android 6–7 |
| `mipmap-*/ic_launcher_foreground.png` (108–432 px) | ~19 KB | Lapisan depan ikon adaptif (Android 8+) |
| `mipmap-anydpi-v26/ic_launcher.xml`, `ic_launcher_round.xml`, `values/colors.xml` | — | Ikon adaptif dengan latar `#FFFFFF` |

Total aset sekitar 73 KB, turun sekitar 82% dari 415 KB.

## 5. Integrasi engine Kotlin ke APK (jalur dasar sudah dipasang)

APK Flutter memasukkan modul Kotlin melalui Gradle dan memakai jalur A (MethodChannel/EventChannel) untuk project, chat, engine API/lokal, server, RAG, dan Hugging Face. Server lokal diekspos untuk klien jaringan melalui `LocalServerService`; Flutter tidak perlu mengakses loopback untuk chat internal.

- **A. Jembatan MethodChannel.** Kelas Kotlin di `flutter_app/android/` memanggil `InferenceEngine`, `ProjectRepository`, dan modul lain. Dart memanggilnya lewat `MethodChannel`. Token streaming lewat `EventChannel`. Kelebihan: memakai kode yang sudah ada langsung dan API-nya terkontrol. Kekurangan: modul Kotlin harus masuk build Flutter.
- **B. Server loopback.** APK menjalankan `LocalServerService` (`:server`), lalu Dart memanggil `http://127.0.0.1:PORT/v1/...` seperti klien OpenAI. Kelebihan: semua endpoint (termasuk SSE) langsung tersedia. Kekurangan: tetap perlu modul Kotlin di APK, dan ada overhead HTTP.

Langkah implementasi awal mencakup `RemoteApiEngine` dan wiring `LlamaCppEngine`; jalur lokal masih bersyarat pada tersedianya library JNI yang dibangun untuk ABI target. Trainer dan operasi model masih perlu alur Flutter ke server Python (HTTP).

Yang masih perlu diselesaikan sebelum rilis:
- Build APK debug/release dan tes JUnit/Kotlin di mesin dengan Flutter dan Android SDK.
- Bangun/masukkan binary JNI llama.cpp untuk ABI target, lalu uji muat model, cancel, dan kebutuhan RAM.
- Tinjau aturan R8 serta izin/FGS pada versi Android target; manifest sudah mendeklarasikan `LocalServerService`.
- Uji alur server, HF, RAG, dan API pada perangkat sungguhan serta tambahkan progres/cancel untuk operasi panjang.

## 6. Verifikasi

**Sudah dilakukan (di lingkungan migrasi):**
- Aset logo dibuat ulang dan diperiksa secara visual (transparansi di latar gelap dan putih, ikon launcher).
- File XML Android (manifest, ikon adaptif, `colors.xml`) diparse tanpa error.
- Pencarian referensi lama (`:app`, `app/src`, `Compose`, `neuran`, `NeuraN`) di seluruh repo. Sisa yang tersisa adalah rujukan yang memang benar (mis. `flutter_app/android/settings.gradle` yang memakai `:app` milik Flutter).
- Semua penggantian teks di `main.dart` dan `pubspec.yaml` diverifikasi jumlahnya (tepat sesuai ekspektasi).

**Belum dilakukan (perlu mesin dengan SDK):**
- `flutter pub get`, `flutter analyze`, `flutter test`, `flutter build apk --debug` dan `--release`.
- `./gradlew :engine:testDebugUnitTest :project:testDebugUnitTest :copilot:testDebugUnitTest`.
- Pengujian di perangkat Android.

Risiko yang harus diperhatikan saat build pertama:
- `flutter_app/lib/main.dart` (satu file, sekitar 33 KB) belum pernah dikompilasi.
- Dependensi `file_picker ^8.1.7` dipakai dengan API v8 (`pickFiles`, `saveFile(bytes: ...)`). Jika versi berbeda, sesuaikan pemanggilannya.
- `key.properties` harus dibuat sebelum build rilis.

## 7. Masalah yang diketahui

- **Typo di logo.** Tulisan di logo sumber berbunyi "NeuroN **Enggine**" (seharusnya "Engine"). Artwork tidak diubah. Di app hanya mark "NE" yang dipakai, jadi typo tidak tampil di UI. Perbaiki di sumber logo sebelum memakai `branding/neuron_logo.png` untuk publikasi.
- **Preview UI.** `flutter_app/design/flutter_preview_v0.2.jpg` mendokumentasikan arah desain Beranda v0.2 sebagai mockup ilustratif; itu bukan screenshot hasil render Flutter atau uji perangkat.
- **Rahasia.** API key engine, token HF, key server lokal, dan API key trainer disimpan di `SecretStore`. Project bridge mengosongkan `remoteTrainerApiKey` ketika menyimpan file konfigurasi dan memigrasikan nilai lama yang mungkin tersimpan sebagai plaintext. Periksa keystore Android; jangan salin secret ke issue/log/repo.
- **Dokumen fitur.** Panduan Server, Copilot, RAG, dan Training mencatat alur Flutter yang tersedia serta kekurangannya. Training remote baru terhubung dasar; split train/val dan ON_DEVICE, serta Vision/Voice, belum memiliki alur UI penuh.
- **Lisensi belum ditentukan.** Tidak ada berkas `LICENSE`.

## 8. Langkah berikutnya (urut)

1. Pada mesin Android: jalankan `flutter pub get`, `flutter analyze`, `flutter test`, `flutter build apk --debug`, lalu tes/compile JUnit dan seluruh modul Kotlin.
2. Jalankan workflow release dengan signing secrets khusus dan pastikan verifier signature lulus; uji install/update serta server start/stop pada perangkat Android yang didukung.
3. Bangun dan uji binary llama.cpp untuk ABI target; uji pemuatan model, pembatalan, konsumsi RAM, serta chat lokal.
4. Uji jaringan: koneksi HTTPS outbound release, HTTP hanya pada debug, server inbound hanya pada interface yang ditampilkan dan tidak terekspos ke jaringan publik.
5. Lengkapi workflow Flutter Training, file workspace, kontrol hardware, operasi file RAG, dan evaluasi Copilot sebelum menyatakan semua modul siap bagi pengguna.
6. Tinjau R8/shrinker, lifecycle foreground service, batas storage, observability, dan kesiapan operasional sesuai [docs/RELEASE.md](RELEASE.md).
