# Penyegaran UI NeuroN Engine — 2026-11-10

## Hasil penerapan

Dua konsep UI diterjemahkan menjadi shell aplikasi yang lebih berorientasi pada alur pengguna:

- Navigasi utama: **Beranda → Chat → Library → Import → Lainnya**.
- **Beranda** menjadi landing screen yang menampilkan status engine, ringkasan server lokal dan knowledge/RAG, shortcut chat/import, serta kejadian terbaru.
- **Chat** dipisahkan dari editor konfigurasi dan memperlihatkan status engine di bagian atas.
- **Library** menampilkan model GGUF terpilih, daftar dokumen knowledge yang dikenal oleh bridge, dan empty state untuk dataset/adapter.
- **Import Center** membedakan sumber perangkat, Hugging Face, dan folder aplikasi. Import dari perangkat meminta tujuan lebih dahulu (model atau Knowledge/RAG).
- Editor berkas project dan alat teknis dipindahkan ke **Lainnya → Editor project / Tools**.
- **Activity** menampilkan log aplikasi yang sudah tersedia. Progress unduhan Hugging Face tetap berada di layar Hugging Face.
- Warna biru menjadi aksen utama; ungu tetap dipakai untuk fitur AI/Copilot.

Implementasi memakai halaman Flutter baru di `flutter_app/lib/app_pages.dart` dan menghubungkannya ke bridge Kotlin yang telah ada. Tidak ada layanan backend atau permission baru yang ditambahkan.

## Batas implementasi saat ini

UI hanya mengarahkan ke fungsi yang telah tersedia. Karena itu, fitur berikut masih belum tersedia dan ditandai apa adanya:

- Import multi-select, review/validasi sebelum import, deduplikasi SHA-256 lintas sumber, dan Activity manager terpusat.
- Impor dataset dan wizard training lengkap dari Flutter.
- Pengunduhan file langsung lewat URL.
- Konektor OAuth Google Drive, Dropbox, atau OneDrive.
- Pairing QR dan transfer jaringan lokal.
- Estimasi ruang/RAM sebelum import, pause/resume universal, checksum review universal, dan operasi Library seperti rename/export/delete.
- Workflow review diff Copilot di Flutter.

Sumber **Perangkat ini** menggunakan picker yang sudah ada untuk model GGUF atau dokumen Knowledge/RAG; tidak mengklaim sebagai file browser penuh dengan multi-select atau preview. Download model HF sudah terhubung ke implementasi yang ada, tetapi Activity lintas pekerjaan belum dipusatkan.

## Verifikasi dan rilis

Versi aplikasi dinaikkan menjadi `0.2.0+2`. Pada lingkungan implementasi ini tidak ditemukan Flutter, Dart, maupun Android SDK. Maka `flutter analyze`, `flutter test`, dan `flutter build apk` tidak dapat dijalankan untuk commit UI ini. Rilis yang dibuat dari perubahan ini adalah **source release** tanpa APK; build/signing dan tes perangkat tetap diperlukan sebelum distribusi biner.

## Saran tahap selanjutnya

1. Jalankan `flutter analyze`, `flutter test`, dan build APK di CI/mesin Android SDK, lalu uji pada perangkat kecil dan tablet.
2. Buat model data Library dan Activity yang persisten agar riwayat import, status validasi, ukuran/hash, dan tindakan file konsisten antarsumber.
3. Bangun alur import bertahap: multi-select → review tujuan per berkas → validasi → progress/cancel/retry → simpan ke Library.
4. Prioritaskan dataset/training Flutter atau Copilot diff review berdasarkan penggunaan nyata; jangan mengaktifkan shortcut sebelum workflow aman dan selesai.
5. Tambahkan transfer URL/HF dengan inspeksi ukuran, ketersediaan ruang, checksum, HTTP warning, dan pembatalan; cloud/LAN sebaiknya menyusul melalui autentikasi/paired token yang aman.
