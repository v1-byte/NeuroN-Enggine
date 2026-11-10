# RAG (tanya jawab dari dokumenmu)

> **Status UI Flutter (2026-11-10):** impor dokumen, pembuatan indeks, dan retrieval saat chat tersedia lewat **Lainnya → Tools → Knowledge / RAG**. Fitur hapus dokumen dan progres terpusat belum tersedia. Periksa [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md) untuk batas UI terbaru.


## Alur
`knowledge/rag.json` -> tombol **Indeks** -> file dibaca -> dipecah per kalimat (chunkSize/chunkOverlap, satuan karakter)
-> di-embedding -> disimpan di SQLite (`files/projects/<nama>/rag.db`). Saat chat dengan `ragEnabled=true`, pertanyaan
di-embedding, `topK` chunk terdekat (cosine) disisipkan ke **pesan terakhir** pengguna, dan nama file sumber tampil di bawah jawaban.

## Cara pakai di Flutter
1. Buka **Lainnya → Tools → Knowledge / RAG** dan tekan **Tambah dokumen**. Pilih file yang didukung; tiap file dibatasi 25 MB dan disalin ke penyimpanan privat aplikasi.
2. Tekan **Buat / perbarui indeks**. Aplikasi memakai engine yang sedang aktif untuk embedding; engine API harus mendukung `/v1/embeddings`.
3. Setelah indeks selesai, buka Chat dan ajukan pertanyaan tentang isi dokumen. RAG menyisipkan konteks hasil retrieval bila knowledge aktif.

Konfigurasi low-level (`knowledge/rag.json`) masih dapat diperiksa di project. Namun, pemilihan model embedding terpisah, pengelolaan folder/path arbitrer, dan penghapusan dokumen belum disediakan di UI Flutter.

## Format
txt, md, csv, json, kode, html, **docx**, **pdf** (PDF hasil scan tidak punya teks: tidak didukung, butuh OCR).

## Catatan
- Ganti model embedding atau chunkSize/chunkOverlap = indeks dibangun ulang otomatis.
- Konteks hanya untuk giliran itu (tidak masuk riwayat), jadi context window tidak cepat penuh, tapi prefix cache KV hanya mengenai sampai pesan pengguna sebelumnya.
- Pencarian brute-force: nyaman sampai puluhan ribu chunk. `minScore` (0..1) membuang hasil kurang mirip; mulai dari 0 lalu naikkan setelah melihat skor nyata.
- Prompt penyisip ada di `RagPrompt` (rag/RagPipeline.kt); ubah jika model kecil kurang patuh.
- Dependensi PDF: `pdfbox-android` (rag/build.gradle.kts). Hapus bersama `PdfText` jika tidak perlu.
- Belum dikompilasi/diuji di perangkat.
