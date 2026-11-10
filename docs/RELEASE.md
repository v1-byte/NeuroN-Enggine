# Rilis APK (Flutter): signing, ABI, dan uji RAM

> **Catatan migrasi (2026-11-09):** APK sekarang dibangun dari `flutter_app/` dengan `flutter build apk`. Build Compose lama (`./gradlew :app:assembleRelease`) sudah tidak ada. Konfigurasi R8/ProGuard yang dulu aktif di modul `app` **belum** ada di `flutter_app/`; lihat bagian 2. Detail migrasi: [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).

## 1. Signing rilis

Keystore tidak disimpan di repo. Buat `flutter_app/android/key.properties` (sudah di `.gitignore`, **jangan di-commit**):
```properties
storePassword=...
keyPassword=...
keyAlias=neuron
storeFile=/path/ke/neuron-release.jks
```
Lalu:
```bash
cd flutter_app
flutter build apk --release
```
- Keluaran: `flutter_app/build/app/outputs/flutter-apk/app-release.apk`. Untuk distribusi, ganti namanya menjadi `NeuroN-Engine-release.apk`.
- Tanpa `key.properties`, build rilis memakai signing debug (`flutter_app/android/app/build.gradle`). Workflow CI v0.2.1 menghasilkan APK untuk **uji instalasi saja**, bukan distribusi produksi.
- Versi diambil dari `flutter_app/pubspec.yaml` (`version: 0.2.1+3` → versionName `0.2.1`, versionCode `3`).

### Build dan upload melalui GitHub Actions

Workflow `.github/workflows/release-apk.yml` berjalan saat GitHub Release dipublikasikan atau dapat dijalankan manual untuk tag release yang sudah ada. Workflow menjalankan analyze/test Flutter, tes Kotlin, lalu `flutter build apk --release` tanpa `--split-per-abi` sehingga menghasilkan satu APK universal. APK dan file SHA-256 diunggah ke GitHub Release. Tanpa keystore rahasia, nama aset memuat `debug-signed` agar batas signing terlihat jelas.

Untuk signing produksi, isi semua GitHub Actions Secrets berikut: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, dan `ANDROID_KEY_PASSWORD`. Workflow membentuk `key.properties` sementara di runner lalu Gradle menandatangani APK dengan keystore itu. Jika semua secrets kosong, workflow membuat APK debug-signed untuk pengujian; jika hanya sebagian yang diisi, build dihentikan. Jangan pernah mengunggah keystore atau password ke repo.

## 2. Minify / R8 / ProGuard

- **Belum aktif** di `flutter_app/`. Modul Compose lama mengaktifkan `minifyEnabled` dan `shrinkResources`, tetapi aturannya (`proguard-rules.pro`) dihapus bersama modul itu.
- Saat modul Kotlin (`:engine`, `:server`, dst.) masuk ke APK, aturan ini wajib ditambahkan lagi:
  - `engine/consumer-rules.pro` sudah ada: seluruh `com.neuron.engine.**` dan method `native` dipertahankan, karena dipanggil dari C++ lewat JNI.
  - Serialisasi kotlinx (serializer data class config) dan WorkManager (konstruktor worker) perlu aturan `keep` sendiri.
- Jika minify diaktifkan, simpan `flutter_app/build/app/outputs/mapping/release/mapping.txt` untuk setiap rilis agar stack trace bisa diterjemahkan.
- Aturan R8 bisa merusak fitur tanpa error saat build, jadi setelah diaktifkan wajib uji fungsi (bagian 5).

## 3. ABI

- `flutter build apk` secara default membangun semua ABI (fat APK). Untuk perangkat arm64 saja:
  ```bash
  flutter build apk --release --target-platform android-arm64
  ```
  atau pisahkan per ABI dengan `--split-per-abi`.
- Engine llama.cpp (`docs/NATIVE.md`) hanya mendukung `arm64-v8a`. Build rilis yang memuat engine lokal **harus** arm64 saja.
- Verifikasi isi APK:
  ```bash
  unzip -l flutter_app/build/app/outputs/flutter-apk/app-release.apk | grep "lib/"
  ```
  Jika engine lokal sudah masuk, hanya `lib/arm64-v8a/` yang boleh muncul.

## 4. Uji RAM 6 / 8 / 12 GB

Activity Flutter menampilkan log aplikasi yang tersedia, tetapi diagnostik RAM total/tersedia, ABI, dan batas heap seperti layar Compose lama belum dibuat ulang. Catat kondisi perangkat secara manual sampai diagnostik tersebut tersedia.

**Matriks uji** (satu baris per kombinasi, catat hasilnya):

| Perangkat | RAM | Model (Q4_K_M) | Context | Threads |
|---|---|---|---|---|
| 6 GB | 6 | 0.5B (~0,4 GB) | 2048 | 4 |
| 6 GB | 6 | 1.5B (~1 GB) | 2048 | 4 |
| 6 GB | 6 | 3B (~2 GB) | 2048 | 4 |
| 8 GB | 8 | 3B (~2 GB) | 2048 | 4 |
| 8 GB | 8 | 7B (~4,5 GB) | 2048 | 4 |
| 12 GB | 12 | 7B (~4,5 GB) | 4096 | 6 |

Angka ukuran model adalah perkiraan; sesuaikan dengan file yang benar-benar diunduh.

**Yang diukur per kombinasi:**
- waktu muat model dan latensi token pertama
- kecepatan (token per detik) untuk 20 giliran
- memori puncak: `adb shell dumpsys meminfo com.neuron.engine | grep -E "TOTAL|Native Heap"`
- apakah app dibunuh sistem: `adb logcat | grep -iE "lowmemory|lmkd|killed"`

**Kriteria lulus:**
- tidak ada kill dari sistem selama 20 giliran
- memori puncak di bawah sekitar 75% RAM total
- balasan lengkap tanpa error `[Error]` di chat

Heuristik ukuran GGUF (sekitar 40% RAM total) hanya titik awal. Ukuran nyata bergantung pada context, KV cache, dan jumlah threads. Jika satu kombinasi gagal, turunkan ukuran model atau context, lalu catat hasilnya.

## 5. Uji fungsi sebelum rilis

Bagian ini mengikuti fitur yang **benar-benar ada** di UI Flutter. Uji berikut ditambahkan bersamaan dengan integrasi engine ke APK.

Alur yang bisa diuji saat ini:
1. Buka `params.json`, ubah temperature lewat Inspektur, dan pastikan JSON tetap valid.
2. Tombol **Rapikan**, **Cari dan ganti**, dan status bar `JSON valid` / `JSON error`.
3. Muat file JSON dari perangkat, lalu simpan lewat dialog sistem.
4. Chat API-compatible, streaming, stop, riwayat Activity, dan pengaturan engine.
5. Model GGUF, Knowledge/RAG, Server lokal, dan Hugging Face melalui layar Tools; inferensi lokal memerlukan library native yang sesuai ABI.

Uji pada perangkat nyata tetap wajib untuk memeriksa picker/import, chat, server/RAG/HF, layout pada ukuran layar berbeda, serta operasi model. Inferensi lokal dan training ON_DEVICE memerlukan binary native dan harus dinyatakan belum tersedia bila binary tidak disertakan.

## 6. Checklist rilis

- [ ] `version:` di `flutter_app/pubspec.yaml` dinaikkan
- [ ] `flutter analyze` dan `flutter test` lulus (belum dijalankan; lihat `docs/MIGRASI_FLUTTER.md` bagian 6)
- [ ] GitHub Actions `Build and publish Android APK` lulus analyze, tes, dan build
- [ ] APK universal dan checksum terlampir di GitHub Release
- [ ] Keystore signing produksi digunakan (wajib sebelum distribusi produksi; debug signing hanya untuk uji)
- [ ] ABI APK sesuai binary native yang benar-benar disertakan
- [ ] Uji fungsi (bagian 5) lulus untuk fitur yang ada di build
- [ ] Matriks RAM (bagian 4) diisi untuk 6, 8, dan 12 GB
- [ ] `mapping.txt` disimpan (jika R8 aktif)
- [ ] Keystore, `key.properties`, dan password tidak masuk ke repo atau artefak
- [ ] `docs/STATUS.md` diperbarui

## 7. Yang belum tersedia

- Vision lokal (mmproj), belum diverifikasi.
- Runtime ONNX (onnxruntime-genai), belum diintegrasikan.
- Konversi AWQ/GPTQ, lihat `docs/CONVERT.md`.
- Fitur native llama.cpp hanya berjalan bila library untuk ABI perangkat disertakan dan diverifikasi.
- Uji di perangkat nyata belum dilakukan dari lingkungan migrasi.
