# NeuroN Engine — UI Flutter (Android)

Ini adalah UI Android NeuroN Engine. Shell dan state aplikasi berada di `lib/main.dart`; halaman utama berada di `lib/app_pages.dart`. Proyek ini adalah entry point APK (`applicationId` `com.neuron.engine`). Dokumentasi lengkap repo ada di [../README.md](../README.md). Catatan migrasi ada di [../docs/MIGRASI_FLUTTER.md](../docs/MIGRASI_FLUTTER.md).

> **Status: UI Flutter alpha.** Beranda, Chat, Library, Import Center, Activity, Workspace, Hugging Face, RAG, Copilot dasar, Server lokal, tema, tutorial, auto-update, dan training remote LoRA/QLoRA tersedia dengan tingkat integrasi berbeda. Build Android dan uji perangkat tetap wajib sebelum publikasi; split train/val dan training ON_DEVICE belum tersedia. Workflow publikasi release membutuhkan signing secrets valid dan memverifikasi signature sebelum upload.

## Menjalankan

Butuh Flutter stable dengan Dart 3.5+ (Flutter 3.24 atau lebih baru) dan Android SDK.

```bash
cd flutter_app
flutter pub get
flutter run                     # emulator atau perangkat Android
flutter build apk --debug       # build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release     # perlu android/key.properties, lihat ../docs/RELEASE.md
flutter analyze
```

Build Android harus diverifikasi pada mesin yang memiliki Flutter, Android SDK, NDK, dan JDK yang sesuai. Workflow CI membangun APK, tetapi hanya run sukses dan artefak yang signature-nya benar menjadi bukti build. Keystore rilis disediakan melalui GitHub Actions Secrets; jangan commit key.properties atau keystore. Native llama.cpp tetap memerlukan build untuk ABI target.

## Struktur

```
flutter_app/
├─ lib/main.dart              shell navigasi, state berkas/chat dan bridge actions
├─ lib/app_pages.dart         Beranda, Library, Import Center, Activity, Lainnya
├─ lib/feature_workspace.dart layar model lokal, server, RAG, Hugging Face, serta tools workspace
├─ lib/training_page.dart     workflow training remote Flutter
├─ lib/tutorial.dart           tutorial onboarding bertahap
├─ lib/bridge.dart            pembungkus MethodChannel/EventChannel ke Kotlin
├─ lib/code_editor.dart       editor kode dengan nomor baris
├─ lib/inspector.dart         Inspektur untuk chat/params.json
├─ lib/chat_pane.dart         panel chat
├─ lib/dialogs.dart           dialog Pengaturan dan Fitur
├─ lib/theme.dart             lima preset tema warna
├─ assets/images/neuron_mark.png   mark "NE" untuk header (didaftarkan di pubspec.yaml)
├─ android/
│  ├─ app/src/main/AndroidManifest.xml     permission, label, cleartext outbound dinonaktifkan
│  ├─ app/src/debug/AndroidManifest.xml    pengecualian HTTP untuk build debug saja
│  ├─ app/src/main/kotlin/com/neuron/engine/MainActivity.kt
│  ├─ app/src/main/kotlin/com/neuron/engine/NeuronBridge.kt   jembatan chat (EventChannel neuron/chat)
│  ├─ app/src/main/kotlin/com/neuron/engine/ProjectBridge.kt  berkas proyek, pengaturan API, fitur (MethodChannel neuron/project)
│  ├─ app/src/main/kotlin/com/neuron/engine/TrainingBridge.kt dataset, upload model, dan job training remote
│  ├─ app/src/main/kotlin/com/neuron/engine/UpdateBridge.kt GitHub Releases dan installer APK
│  ├─ app/src/main/res/mipmap-*/           ikon launcher dan lapisan depan ikon adaptif
│  ├─ app/src/main/res/mipmap-anydpi-v26/  ikon adaptif (latar dari values/colors.xml)
│  ├─ app/build.gradle                      applicationId, minSdk 26, jniLibs legacy packaging
│  └─ key.properties                        (tidak di repo) keystore rilis
├─ design/                    preview UI v0.2 (mockup ilustratif, JPG)
├─ pubspec.yaml               nama neuron_engine, versi 0.2.4+6
└─ analysis_options.yaml      flutter_lints
```

## Yang sudah dan belum

| Bagian | Di UI sekarang |
|---|---|
| Berkas/editor | Workspace dan konfigurasi terbatas; bukan browser penuh untuk semua berkas virtual atau editor IDE multi-file |
| Inspektur | Subset parameter chat (temperature, top-p, top-k, max tokens, seed) |
| Pengaturan | Base URL dan model di proyek. API key di SecretStore, tidak ditulis ke `project.json` |
| Chat | Streaming melalui `EngineHub`: API atau LOCAL llama.cpp; RAG menambahkan konteks retrieval bila indeks tersedia |
| Fitur | Tool calling (`current_time`, `calculate`) dan guardrail kata/regex tersambung. Vision, TTS, dan STT belum tersedia sebagai alur UI Flutter |
| Log | Kejadian nyata dari aplikasi (simpan, chat, error) |
| Copilot | Meminta saran dan menerapkan patch yang ditinjau tersedia; evaluasi lanjutan dan alur undo/reject bertingkat belum tersedia |
| Hugging Face | Cari repo GGUF, lihat ukuran file, unduh, progress, cancel, checksum, dan aktivasi model otomatis |
| Latih | Pilih model lokal atau impor GGUF, upload model ke trainer, validasi dataset, start/progres/log/stop/sambung, unduh ZIP/LoRA GGUF; split train/val dan ON_DEVICE belum tersedia |
| Server | Pengaturan port/key, pembuatan key acak 256-bit, konfirmasi risiko HTTP, start/stop/status tersedia; inbound tetap HTTP tanpa TLS |
| Data & RAG | Impor dokumen, indeks SQLite, retrieval chat tersedia; hapus dokumen/progres belum ada |
| Hardware | Inspector belum tersedia; konfigurasi bisa diedit melalui `hardware/engine.json` |
| Model lokal | Import dari Download/internal storage, daftar ukuran/status aktif, dan pemilihan ulang tersedia; inferensi memerlukan library native yang cocok dengan ABI perangkat |
| Tema/tutorial/update | Lima tema warna, tutorial modal, animasi navigasi, dan auto-update GitHub Releases tersedia |

Peta lengkap ke fitur di modul Kotlin ada di [../docs/MIGRASI_FLUTTER.md](../docs/MIGRASI_FLUTTER.md) bagian 3.

## Mengubah logo dan ikon

Jangan mengedit aset hasil secara manual. Buat ulang dari logo sumber (PNG transparan, minimal 1024 px) dari root repo:

```bash
python3 scripts/make_brand_assets.py --src /path/ke/logo-sumber.png
```

Skrip ini menulis ulang `assets/images/neuron_mark.png` dan semua `ic_launcher*.png`. Logo penuh untuk dokumentasi ada di `../branding/neuron_logo.png`.

## Catatan

- UI sudah dipecah per berkas di `lib/`. Pindahkan layar fitur ke `lib/screens/` bila alur makin besar.
- Android release memblokir koneksi cleartext keluar; server lokal masuk tetap HTTP dan hanya disarankan pada jaringan tepercaya. Debug build mengizinkan HTTP untuk development.
- Build APK dan uji perangkat tetap wajib sebelum rilis. Lihat `../docs/RELEASE.md` dan `../docs/SERVER.md`.
- Preview di `design/flutter_preview_v0.2.jpg` adalah mockup arah desain, bukan screenshot Flutter dari perangkat. Rincian shell dan batas fitur ada di `../docs/UI_REFRESH.md`.
