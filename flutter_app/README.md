# NeuroN Engine — UI Flutter (Android)

Ini adalah UI Android NeuroN Engine. Shell dan state aplikasi berada di `lib/main.dart`; halaman utama berada di `lib/app_pages.dart`. Proyek ini adalah entry point APK (`applicationId` `com.neuron.engine`). Dokumentasi lengkap repo ada di [../README.md](../README.md). Catatan migrasi ada di [../docs/MIGRASI_FLUTTER.md](../docs/MIGRASI_FLUTTER.md).

> **Status: UI 0.2.2 alpha.** Shell mobile-first menggantikan tampilan editor-first dan rail kiri lama. Beranda, Chat, Library, Import Center, Activity, serta Workspace tersedia; editor konfigurasi tetap berada di Lainnya → Workspace. Workflow GitHub Actions membangun APK universal pada rilis. APK CI memakai debug signing sampai pemilik menyiapkan keystore privat; bukan untuk distribusi produksi.

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

Build lokal belum dapat dijalankan di lingkungan dokumentasi ini karena Flutter/Dart dan Android SDK tidak terpasang. Untuk memeriksa status build rilis, lihat workflow **Build and publish Android APK** pada GitHub Actions.

## Struktur

```
flutter_app/
├─ lib/main.dart              shell navigasi, state berkas/chat dan bridge actions
├─ lib/app_pages.dart         Beranda, Library, Import Center, Activity, Lainnya
├─ lib/feature_workspace.dart layar model lokal, server, RAG, Hugging Face, serta status fitur tertunda
├─ lib/bridge.dart            pembungkus MethodChannel/EventChannel ke Kotlin
├─ lib/code_editor.dart       editor kode dengan nomor baris
├─ lib/inspector.dart         Inspektur untuk chat/params.json
├─ lib/chat_pane.dart         panel chat
├─ lib/dialogs.dart           dialog Pengaturan dan Fitur
├─ lib/theme.dart             warna dan tema
├─ assets/images/neuron_mark.png   mark "NE" untuk header (didaftarkan di pubspec.yaml)
├─ android/
│  ├─ app/src/main/AndroidManifest.xml     permission, label "NeuroN Engine", FlutterActivity
│  ├─ app/src/main/kotlin/com/neuron/engine/MainActivity.kt
│  ├─ app/src/main/kotlin/com/neuron/engine/NeuronBridge.kt   jembatan chat (EventChannel neuron/chat)
│  ├─ app/src/main/kotlin/com/neuron/engine/ProjectBridge.kt  berkas proyek, pengaturan API, fitur (MethodChannel neuron/project)
│  ├─ app/src/main/res/mipmap-*/           ikon launcher dan lapisan depan ikon adaptif
│  ├─ app/src/main/res/mipmap-anydpi-v26/  ikon adaptif (latar dari values/colors.xml)
│  ├─ app/build.gradle                      applicationId, minSdk 26, jniLibs legacy packaging
│  └─ key.properties                        (tidak di repo) keystore rilis
├─ design/                    preview UI v0.2 (mockup ilustratif, JPG)
├─ pubspec.yaml               nama neuron_engine, versi 0.2.2+4
└─ analysis_options.yaml      flutter_lints
```

## Yang sudah dan belum

| Bagian | Di UI sekarang |
|---|---|
| Berkas | 17 berkas virtual dari `VirtualTree`, dibaca dan ditulis lewat `neuron/project`. Disimpan ke `project.json` setelah validasi. Undo/redo per berkas |
| Editor kode | Nomor baris, cari dan ganti semua, Rapikan untuk JSON, status JSON valid |
| Inspektur | Untuk `chat/params.json`: slider temperature, top-p, top-k, max tokens; seed |
| Pengaturan | Base URL dan model di proyek. API key di SecretStore, tidak ditulis ke `project.json` |
| Chat | Streaming melalui `EngineHub`: API atau LOCAL llama.cpp; RAG menambahkan konteks retrieval bila indeks tersedia |
| Fitur | Tool calling (`current_time`, `calculate`) dan guardrail kata/regex, dipasang lewat `EngineFactory.wrap`. Vision, TTS, dan STT belum ada |
| Log | Kejadian nyata dari aplikasi (simpan, chat, error) |
| Copilot | Modul agent tersedia, tetapi alur permintaan saran, diff, terima/tolak, dan eval belum dibuat ulang |
| Hugging Face | Cari repo GGUF, lihat file, unduh dan verifikasi checksum tersedia; progres per-byte belum tampil |
| Latih | UI dataset, job/progres, stop, dan unduh adapter belum dihubungkan |
| Server | Pengaturan port/key, start/stop, dan status tersedia; perlu uji di Android |
| Data & RAG | Impor dokumen, indeks SQLite, retrieval chat tersedia; hapus dokumen/progres belum ada |
| Hardware | Inspector belum tersedia; konfigurasi bisa diedit melalui `hardware/engine.json` |
| Model lokal | Pemilihan GGUF tersedia; inferensi memerlukan library native yang cocok dengan ABI perangkat |

Peta lengkap ke fitur di modul Kotlin ada di [../docs/MIGRASI_FLUTTER.md](../docs/MIGRASI_FLUTTER.md) bagian 3.

## Mengubah logo dan ikon

Jangan mengedit aset hasil secara manual. Buat ulang dari logo sumber (PNG transparan, minimal 1024 px) dari root repo:

```bash
python3 scripts/make_brand_assets.py --src /path/ke/logo-sumber.png
```

Skrip ini menulis ulang `assets/images/neuron_mark.png` dan semua `ic_launcher*.png`. Logo penuh untuk dokumentasi ada di `../branding/neuron_logo.png`.

## Catatan

- UI sudah dipecah per berkas di `lib/`. Pindahkan layar fitur ke `lib/screens/` bila alur makin besar.
- Aturan R8 belum ada. Build APK dan uji shrinker tetap wajib sebelum rilis.
- Preview di `design/flutter_preview_v0.2.jpg` adalah mockup arah desain, bukan screenshot Flutter dari perangkat. Rincian shell dan batas fitur ada di `../docs/UI_REFRESH.md`.
