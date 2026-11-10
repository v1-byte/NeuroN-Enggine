# Dataset: import, validasi, pratinjau, dan split train/val (langkah 18)

> **Status UI Flutter (2026-11-10):** layar **Latih** mendukung pemilihan JSONL/JSON/CSV, pemeriksaan semua record, pratinjau, dan penggunaan dataset bersih langsung sebagai data train. Split train/val belum dihubungkan ke Flutter. Alur lama di bawah yang menyebut menu Data/aksi split menggambarkan rancangan legacy, bukan tombol aktif. Lihat [TRAINING.md](TRAINING.md) dan [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).


## 1. Alur
1. Buka **Lainnya → Training** (atau Import Center → Dataset training).
2. Pilih berkas `.jsonl`, `.json`, atau `.csv`. File disalin ke penyimpanan privat aplikasi (`filesDir/datasets/`).
3. Periksa jumlah record valid/error dan pratinjau. UI menolak memulai training bila dataset memiliki error; perbaiki sumber lalu pilih ulang.
4. Dataset bersih dipakai langsung sebagai data train dan diunggah ke server saat menekan **Mulai training**. UI saat ini belum membuat validation split.

## 2. Format yang diterima
| Format | Syarat |
|---|---|
| `.jsonl` (disarankan) | Satu objek JSON per baris. Baris kosong dilewati. |
| `.json` | Array objek JSON. Dibatasi 64 MB karena dimuat penuh ke memori. |
| `.csv` | Baris pertama header. Satu baris per record: baris dengan tanda kutip tidak seimbang (record multiline) ditolak. |

Aturan per metode (`training/train.json` → `method`):
- **SFT / LORA / QLORA / FULL_FINETUNE**: `messages` (array dengan `role` system/user/assistant/tool, `content` tidak kosong, dan minimal satu `assistant`), atau `instruction`/`prompt` + `output`/`response`.
- **DPO**: `prompt`, `chosen`, dan `rejected` wajib dan tidak kosong.
- **RLHF**: belum didukung trainer server (lihat `train_lora.py`).

## 3. Split
- Split selalu menghasilkan `train.jsonl` dan `val.jsonl` di `filesDir/datasets/<nama>/`.
- Jumlah val = `round(valid × rasio)`, minimal 1 bila rasio > 0.
- Pemilihan record memakai `Random(seed)` atas indeks, jadi seed yang sama selalu menghasilkan pembagian yang sama.
- Split **ditolak** jika ada error, supaya tidak ada record yang hilang diam-diam. Perbaiki file lalu pilih ulang.
- Split **ditolak** jika metode di `train.json` berbeda dari saat file dipilih, karena aturan validasinya bisa berbeda.
- Rasio 0 menghasilkan hanya `train.jsonl`, dan `valDatasetPath` dikosongkan.

## 4. Sisi server (`python/`)
- `POST /train` menerima `val_dataset` (opsional). Bila diisi, file itu harus sudah diunggah.
- `train_lora.py --val <file>` memuat dataset validasi dan mengaktifkan `eval_strategy="epoch"`.
- Event `eval_loss` dikirim sebagai baris log (`eval_loss=0.1234`). Event ini tidak dihitung sebagai step loss.
- Membutuhkan transformers yang mendukung `eval_strategy` (4.41 atau lebih baru). Versi lama memakai nama `evaluation_strategy`.

## 5. Batasan
- **Tidak ada grafik loss dan tombol unduh adapter.** Itu langkah 19.
- **CSV multiline belum didukung.** Ubah ke JSONL jika data punya teks dengan baris baru di dalam sel.
- **Split tidak stratifikasi.** Dataset yang sangat tidak seimbang (mis. satu kategori dominan) bisa menghasilkan val yang kurang representatif.
- **Belum dikompilasi dan belum diuji** di perangkat maupun server.
