# RAG (tanya jawab dari dokumenmu)

> **Catatan migrasi (2026-11-09):** layar dan tombol di dokumen ini berasal dari UI Compose lama, yang sudah dihapus dari repo. UI Flutter (`flutter_app/`) belum memiliki bagian ini; logika di modul di bawahnya tidak berubah. Lihat [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).


## Alur
`knowledge/rag.json` -> tombol **Indeks** -> file dibaca -> dipecah per kalimat (chunkSize/chunkOverlap, satuan karakter)
-> di-embedding -> disimpan di SQLite (`files/projects/<nama>/rag.db`). Saat chat dengan `ragEnabled=true`, pertanyaan
di-embedding, `topK` chunk terdekat (cosine) disisipkan ke **pesan terakhir** pengguna, dan nama file sumber tampil di bawah jawaban.

## Cara pakai
1. Siapkan model embedding GGUF **terpisah** (jangan pakai model chat: kualitasnya buruk). Untuk bahasa Indonesia pilih
   yang multibahasa, mis. multilingual-e5-small atau bge-m3 (Q8/Q4). Isi `embeddingModelPath`.
2. Salin dokumen ke folder knowledge: `adb push catatan.pdf /sdcard/Android/data/com.neuron.engine/files/knowledge/`
3. `knowledgeFiles`: `["catatan.pdf", "folder/"]` (relatif = folder di atas; `"."` = semuanya; path absolut dan `content://` juga bisa).
4. `ragEnabled`: true. Simpan, lalu tekan **Indeks** (log di panel Log). Indeks ulang hanya file yang berubah (hash isi).
5. Chat seperti biasa.

## Format
txt, md, csv, json, kode, html, **docx**, **pdf** (PDF hasil scan tidak punya teks: tidak didukung, butuh OCR).

## Catatan
- Ganti model embedding atau chunkSize/chunkOverlap = indeks dibangun ulang otomatis.
- Konteks hanya untuk giliran itu (tidak masuk riwayat), jadi context window tidak cepat penuh, tapi prefix cache KV hanya mengenai sampai pesan pengguna sebelumnya.
- Pencarian brute-force: nyaman sampai puluhan ribu chunk. `minScore` (0..1) membuang hasil kurang mirip; mulai dari 0 lalu naikkan setelah melihat skor nyata.
- Prompt penyisip ada di `RagPrompt` (rag/RagPipeline.kt); ubah jika model kecil kurang patuh.
- Dependensi PDF: `pdfbox-android` (rag/build.gradle.kts). Hapus bersama `PdfText` jika tidak perlu.
- Belum dikompilasi/diuji di perangkat.
