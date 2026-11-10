# Copilot: saran perbaikan konfigurasi + eval sebelum/sesudah

> **Status UI Flutter (2026-11-10):** layar **Lainnya → Tools → Copilot** dapat meminta saran, menampilkan teks sebelum/usulan per file, dan mensyaratkan checkbox review sebelum menerapkan patch. Evaluasi sebelum/sesudah serta undo/reject bertingkat belum tersedia di Flutter. Status rinci: [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).


Copilot membaca keluhanmu, lalu mengusulkan perubahan ke file konfigurasi project. Kamu meninjau setiap perubahan
sebagai diff, lalu menerima atau menolaknya. Eval membandingkan jawaban model sebelum dan sesudah perubahan.

## 1. Alur kerja

Di Flutter, buka **Lainnya → Tools → Copilot**, masukkan keluhan dan contoh output (opsional), lalu tekan **Minta saran**. Untuk setiap patch valid, baca teks sebelum dan teks usulan, centang persetujuan review, lalu tekan **Terapkan patch yang ditinjau**. Engine/provider aktif akan digunakan.

UI Flutter menampilkan isi sebelum/usulan, tetapi belum menyediakan diff berwarna/berbaris atau evaluasi sebelum/sesudah dan undo/reject bertingkat. Persetujuan pengguna tetap wajib; periksa hasil pada workspace setelah perubahan.

Perubahan yang diterima langsung disimpan ke project. Kamu bisa membatalkan dengan mengedit file lalu menyimpannya kembali.

## 2. Aturan keamanan
- **Copilot tidak pernah menulis sendiri.** Setiap perubahan butuh persetujuanmu.
- **Setiap usulan divalidasi** dengan skema yang sama seperti editor (`VirtualTree.write`). Usulan yang tidak valid ditandai error dan tidak bisa diterima.
- **File yang dilarang:** `engine/api.json` (berisi API key), `eval/cases.json` (agar Copilot tidak mengubah soal ujinya sendiri), `model/quantization.json`, `model/lora.json`, `model/ops.json`, dan `training/train.json`.
- **Konflik dicek.** Jika kamu mengedit file setelah saran dibuat, usulan untuk file itu ditolak dan kamu diminta meminta saran ulang.
- **Tombol terima dikunci** saat editor punya perubahan belum disimpan.

## 3. Format balasan model (untuk referensi)
Copilot meminta model membalas satu objek JSON:
```json
{"reason":"jawaban terlalu panjang","changes":[
  {"path":"chat/params.json","merge":{"maxTokens":128,"temperature":0.4}},
  {"path":"chat/system_prompt.md","content":"Jawab singkat dalam bahasa Indonesia."}
]}
```
- File JSON memakai `merge` (JSON Merge Patch, RFC 7386): hanya field yang diubah. `null` menghapus field.
- File teks (`chat/system_prompt.md`, `model/Modelfile`, `model/chat_template.jinja`) memakai `content` penuh.
- Model kecil (<3B) sering salah format. Jika balasan tidak berisi JSON, Copilot menampilkan pesan error dan kamu bisa minta ulang.

## 4. Kasus eval (`eval/cases.json`)
Buka **eval/cases.json** di Explorer. Contoh:
```json
{
  "cases": [
    {"name":"sapa","prompt":"Halo, siapa namamu?","mustContain":["asisten"],"mustNotContain":["sebagai AI"]},
    {"name":"singkat","prompt":"Apa ibu kota Indonesia?","mustContain":["Jakarta"]}
  ],
  "maxTokens": 256
}
```
- `prompt`: pertanyaan yang dikirim ke model (wajib).
- `mustContain`: semua kata harus muncul di jawaban (tanpa membedakan huruf besar/kecil).
- `mustNotContain`: tidak boleh ada kata ini.
- Jawaban kosong selalu dianggap gagal.
- `maxTokens`: batas panjang jawaban saat eval.

Eval memakai temperature 0 dan seed tetap, sehingga hasil antar-putaran lebih stabil.

## 5. Batasan yang perlu diketahui
- **Eval hanya memeriksa kata.** Ini tidak mengukur kualitas jawaban secara menyeluruh. Gunakan kasus yang spesifik dan tambah kasus seiring waktu.
- **Jumlah kasus kecil** membuat perbedaan hasil mudah terjadi karena kebetulan. Anggap hasil sebagai petunjuk, bukan bukti.
- **Context window HP terbatas.** Copilot hanya mengirim isi empat file fokus (`chat/params.json`, `chat/system_prompt.md`, `knowledge/rag.json`, `hardware/engine.json`). Nama file lain ikut disebut, tetapi isinya tidak.
- **Ganti model memuat ulang engine.** Jika eval sesudah mengubah konfigurasi yang memengaruhi model (mis. hardware atau path model), model akan dimuat ulang dan eval lebih lama.
- **Belum dikompilasi/diuji di perangkat.**
