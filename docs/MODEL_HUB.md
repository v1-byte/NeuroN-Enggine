# Model Hub (model GGUF lokal)

Alur satu pintu untuk memakai model lokal: **pilih → unduh → aktif otomatis → chat**.

## Model AI Froged N1

Katalog Model Hub menyediakan **Froged N1 (Qwen2.5 0.5B)** dari repository Hugging Face berikut:

- [Buka repository Froged N1 di Hugging Face](https://huggingface.co/bytecode66/Froged_N1)
- [Unduh file GGUF langsung](https://huggingface.co/bytecode66/Froged_N1/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf?download=true)

Model ini berukuran sekitar 469 MiB untuk kuantisasi Q4_K_M. Dari aplikasi, buka **Model Hub → Froged N1 (Qwen2.5 0.5B) → Unduh & pakai** agar file dipilih, diunduh, diverifikasi bila checksum tersedia, dan diaktifkan otomatis.

## Alur
1. Beranda/Import → **Model Hub** (atau tombol "Unduh model di Model Hub" saat chat kosong).
2. Katalog (`kModelCatalog` di `flutter_app/lib/model_hub.dart`) menampilkan model GGUF ringan dengan label kecocokan RAM
   (dari `Bridge.deviceHealth().recommendedMaxModel`).
3. **Unduh & pakai**: file GGUF dipilih otomatis dari daftar file repo (`pickGguf`: Q4_K_M → Q4_K_S → Q4_0 → Q5_K_M → Q3_K_M → Q8_0;
   shard, mmproj, imatrix diabaikan). Ruang penyimpanan diperiksa sebelum mulai.
4. Progres byte, kecepatan, ETA, jeda/lanjut/batal memakai `HfDownloadWorker` (WorkManager) yang sudah ada.
   Data ditulis ke `<file>.part` dan baru menjadi `<file>.gguf` setelah SHA-256 cocok; file dan checksum diambil dari satu commit
   (revision yang sama dengan yang dicatat di sidecar `.neuron.json`).
5. Setelah selesai, model diaktifkan (`activateLocalModel`, mode LOCAL) dan tombol **Mulai chat** muncul.

## Jalankan, atur, dan edit
- **Jalankan / Hentikan**: memuat model aktif ke memori sekarang (`runModel`) atau melepasnya (`unloadModel`), dengan indikator status dan waktu muat.
- **Pengaturan**: edit prompt sistem, temperature, maks token, dan panjang konteks; disimpan ke `chat/params.json` lewat validasi VirtualTree.
- **Ganti nama** model terpasang, **Pakai**, dan **Hapus** dari daftar "Terpasang di perangkat".
- Chat: **Edit** pesan pengguna lalu kirim ulang dari titik itu, dan **Ulangi** jawaban terakhir.

## Baca model total (Editor GGUF)
Buka dari **Lainnya → Tools → Editor GGUF**, atau tombol *Edit metadata* di daftar model. Model yang diunduh lewat Model Hub
(termasuk subfolder `bytecode66__Froged_N1/`) dan model yang diimpor dari HP muncul di daftar yang sama.
- **Ringkasan**: arsitektur, versi GGUF, kuantisasi (dari `general.file_type`), jumlah parameter, jumlah blok, jumlah token, dan ukuran per tipe tensor.
- **Pemeriksaan integritas**: hijau "Terbaca utuh" bila semua tensor ada di dalam berkas. Merah bila ada tensor melewati akhir berkas
  (unduhan belum selesai/terpotong), tidak sejajar, tumpang tindih, bertipe tidak dikenal, atau jumlah blok tidak cocok dengan header.
  Model terpotong tidak bisa disimpan sebagai salinan; unduh ulang lewat Model Hub.
- **Tensor**: bagian yang bisa dibuka; dimuat 100 per halaman dan bisa dicari (mis. `blk.3`, `attn`, `token_embd`).
- **Array** (mis. `tokenizer.ggml.tokens`): ketuk barisnya untuk membaca isinya per halaman; array hanya bisa dibaca, tidak diedit.
- Data bobot tidak dimuat ke memori; hanya header dan tabel tensor yang dibaca, jadi aman untuk model ratusan MB.

## Onboarding, riwayat, dan ketahanan (v0.3.0)
- **Onboarding** (`onboarding.dart`) tampil sekali bila belum ada engine terkonfigurasi: cek perangkat → rekomendasi (`recommendModel`) → unduh otomatis.
- **Riwayat percakapan** (`conversation_store.dart`): arsip di SharedPreferences, maks 50, judul otomatis; "Percakapan baru" mengarsipkan yang lama.
- **Render chat** (`markdown_text.dart`): teks tebal, `kode`, judul, dan blok kode dengan tombol Salin; blok yang belum ditutup saat streaming tetap tampil sebagai kode.
- **Pulihkan unduhan**: id unduhan disimpan; membuka ulang Model Hub melanjutkan pemantauan atau menyelesaikan aktivasi.
- **Pesan error** (`errors.dart`) diterjemahkan ke kalimat yang bisa ditindaklanjuti; pesan asli tetap masuk log.
- **Tentang** (`app_info.dart`): versi dan identitas pembuat; ubah konstanta di file itu. Versi harus sama dengan `pubspec.yaml` dan `CHANGELOG.md` (dicek CI).

## Chat dan Copilot memakai model yang sama
- Chat membaca engine aktif lewat `EngineHub.ensure`; model dimuat saat pesan pertama (bubble menampilkan "Memuat model…").
- Tombol **Perbaiki** pada balasan asisten membuka Copilot dengan balasan itu sebagai contoh masalah.
  Copilot memakai engine lokal aktif yang sama; lihat `docs/COPILOT.md`.
- `CopilotAgent.suggest` membuang blok `<think>`, mengambil JSON dari balasan, dan mengulang satu kali dengan prompt perbaikan bila
  model lokal kecil membalas JSON rusak. Gagal dua kali → pesan jelas yang menyarankan model lokal yang lebih besar.

## Batasan yang perlu diketahui
- **Belum dikompilasi/diuji** (Flutter/Kotlin tidak tersedia saat perubahan ini dibuat). Jalankan `flutter analyze`, `flutter test`, build APK, dan uji di perangkat.
- Chat lokal butuh library native (`-PwithNative`, lihat `docs/NATIVE.md`); tanpa itu Model Hub tetap mengunduh dan memilih model, lalu memberi peringatan.
- Nama repo di katalog perlu diverifikasi sebelum rilis (repo bisa berganti/dihapus). Nama file tidak di-hardcode.
- Ukuran di katalog adalah perkiraan Q4_K_M. Status unduhan yang sedang berjalan tidak dipulihkan di layar bila halaman ditutup (unduhan tetap berjalan di latar belakang; lihat riwayat di Hugging Face).
- Model kecil (≤1.5B) kurang andal untuk patch JSON Copilot; gunakan 3B ke atas bila memungkinkan.
