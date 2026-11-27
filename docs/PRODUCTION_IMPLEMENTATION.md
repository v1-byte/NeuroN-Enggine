# Production implementation

Tanggal pembaruan: 2026-11-11

Dokumen ini mencatat bagian dari `docs/CATATAN_PRODUCTION_1-18.txt` yang sudah diimplementasikan di repository, bukan sekadar rencana.

## Sudah diimplementasikan

- **Automated testing dan security gate:** workflow Android menjalankan `flutter analyze`, `flutter test`, unit test Kotlin, Gradle compile, Android lint, `git diff --check`, Gitleaks, smoke build debug/release, checksum SHA-256 APK, batas ukuran APK, dan pemeriksaan manifest cleartext.
- **Review production:** `.github/CODEOWNERS` ditambahkan untuk perubahan Flutter, engine, model, Python, dan workflow. Branch protection tetap harus diaktifkan pada pengaturan repository oleh maintainer.
- **Secret storage:** API key dan token yang digunakan aplikasi tetap disimpan melalui `SecretStore` berbasis Android Keystore. Token tidak ditulis ke `project.json`.
- **Device Health Check:** modul model menyediakan snapshot RAM total/bebas, storage bebas, CPU core, ABI, SDK, low-memory state, rekomendasi ukuran model, serta peringatan sebelum model besar dimuat.
- **Model Library:** daftar model lokal menampilkan ukuran, SHA-256, waktu perubahan, dan estimasi RAM. Tersedia `Pakai`, `Rename`, `Verifikasi SHA-256`, `Lihat metadata`, dan `Hapus`; model aktif ditolak untuk dihapus agar konfigurasi tidak rusak.
- **Download model:** WorkManager tetap digunakan untuk job background, resume byte, retry jaringan, progress, cancel, pemeriksaan ruang, dan verifikasi SHA-256 dari Hugging Face bila tersedia.
- **Download Manager:** request download dan riwayat 30 pekerjaan disimpan lokal. UI menampilkan queued/running/paused/succeeded/failed, byte progress, speed, ETA, retry WorkManager, pause/resume/cancel, serta filter ukuran dan quantization GGUF.
- **Staged release:** `.github/workflows/staged-release.yml` menyediakan gate manual `dev`, `beta`, dan `stable` dengan pemeriksaan dokumentasi serta laporan artefak.
- **UI:** halaman Hardware sekarang menampilkan health check; halaman Model lokal menampilkan checksum dan aksi `Pakai`/`Hapus`.

## Cara verifikasi

```bash
# Kotlin dan Android library
./gradlew testDebugUnitTest lintDebug --no-daemon

# Flutter
cd flutter_app
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Pada perangkat Android, buka **Lainnya → Hardware** sebelum mengaktifkan GGUF besar. Periksa peringatan RAM/storage dan ABI. Di **Model lokal**, checksum ditampilkan untuk setiap model dan model aktif harus dinonaktifkan sebelum dihapus.

## Belum otomatis selesai

Item berikut memerlukan infrastruktur atau pengujian eksternal dan tidak boleh dinyatakan selesai hanya karena dokumentasi:

- Branch protection dan aturan wajib PR harus diaktifkan pada pengaturan GitHub.
- Crash reporting privat belum dipasang; jangan kirim isi chat, token, dataset, atau model ke layanan telemetry.
- Staged release dan beta tester memerlukan channel distribusi serta perangkat nyata.
- Onboarding multi-langkah penuh, filter metadata Hugging Face lintas repository, dan riwayat download terpusat masih bertahap. Filter ukuran/quantization dan pause/resume aktif untuk alur download saat ini.
- APK release production tetap membutuhkan keystore privat, verifikasi signature, dan uji instal/update pada perangkat.
- Training on-device, vision, TTS/STT, dan runtime ONNX tetap memiliki batasan seperti yang dijelaskan di `docs/STATUS.md`.

Catatan sumber lengkap: [CATATAN_PRODUCTION_1-18.txt](CATATAN_PRODUCTION_1-18.txt).
