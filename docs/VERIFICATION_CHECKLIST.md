# Checklist verifikasi NeuroN Engine

Dokumen ini membedakan implementasi kode, verifikasi yang dapat dijalankan di CI, dan verifikasi yang membutuhkan perangkat Android fisik.

## Verifikasi otomatis

- `flutter analyze` dan `flutter test` dijalankan oleh workflow `.github/workflows/android.yml`.
- `./gradlew testDebugUnitTest --no-daemon` dijalankan oleh workflow.
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

## Fitur UI yang sebelumnya tertunda

- Unduhan Hugging Face sekarang memakai WorkManager foreground job, progress byte-level (`done`/`total`), resume, dan cancel dari UI Flutter.
- Copilot sekarang memiliki bridge Flutter/Kotlin untuk meminta saran, menampilkan patch per file, dan menerapkan patch setelah ditinjau. Uji provider/model nyata dan evaluasi kualitas saran tetap memerlukan perangkat/endpoint yang dikonfigurasi.
- Pelatihan masih memiliki modul Kotlin backend, tetapi orkestrasi dataset, konfigurasi job, progres, pembatalan, dan pengambilan adapter dari UI Flutter belum selesai.
- Binary `libllamafinetune.so` dan flag CLI training on-device belum disertakan; ON_DEVICE tetap tidak boleh dinyatakan siap produksi.

## Model Hub, chat, dan onboarding (uji perangkat, v0.3.0)

Semua poin di bawah belum pernah dijalankan; centang setelah diuji pada APK build `-PwithNative` di perangkat arm64.

- [ ] Instal bersih: onboarding muncul sekali; "Unduh dan mulai" membuka Model Hub dan unduhan mulai otomatis; "Lewati" tidak mengunduh.
- [ ] Katalog: tiap repo di `kModelCatalog` resolve ke satu file GGUF (tidak ada 404/gated tak terduga). Catat repo yang gagal.
- [ ] Unduh: progres, kecepatan, ETA; jeda/lanjut; batal; matikan jaringan di tengah unduhan lalu cek pesan error; tutup lalu buka lagi halaman Model Hub saat unduhan berjalan (harus pulih).
- [ ] Penyimpanan hampir penuh: unduhan ditolak dengan pesan jelas.
- [ ] Jalankan: waktu muat model tampil; peringatan RAM muncul pada perangkat RAM kecil; Hentikan melepas memori (cek RSS).
- [ ] Chat: token mengalir, Stop bekerja, kecepatan token/dtk masuk akal, blok kode tampil dan tombol Salin berfungsi, markdown tidak merusak teks panjang.
- [ ] Edit pesan pengguna dan Ulangi jawaban: konteks terpotong benar (jawaban lama tidak ikut dikirim); coba setelah satu giliran yang gagal dan setelah jawaban yang dihentikan.
- [ ] Riwayat: percakapan baru mengarsipkan yang lama; buka dari Riwayat; hapus satu/semua; restart aplikasi tidak menghilangkan arsip.
- [ ] Pengaturan model: nilai tidak valid ditolak; ubah panjang konteks memuat ulang model pada pesan berikutnya.
- [ ] Copilot dengan model lokal 1.5B dan 3B: catat berapa kali JSON gagal; tombol Perbaiki membawa jawaban ke Copilot.
- [ ] Tentang: versi sama dengan `pubspec.yaml`.
