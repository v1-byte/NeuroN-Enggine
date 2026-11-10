# Dataset: import, validasi, pratinjau, dan split train/val (langkah 18)

> **Catatan migrasi (2026-11-09):** layar dan tombol di dokumen ini berasal dari UI Compose lama, yang sudah dihapus dari repo. UI Flutter (`flutter_app/`) belum memiliki bagian ini; logika di modul di bawahnya tidak berubah. Lihat [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).


## 1. Alur
1. Buka **📚 Data** di baris bawah Workbench.
2. Pilih file. File disalin ke penyimpanan app (`filesDir/datasets/`), karena trainer membaca dari path lokal.
3. Periksa hasil: jumlah record, jumlah valid, daftar error (30 pertama, tetapi jumlah totalnya selalu lengkap), dan pratinjau 3 record valid.
4. Jika tidak ada error, isi **rasio val** (default 0.1) dan **seed** (default 42), lalu tekan **Buat split & pakai di training**.
5. Hasilnya tersimpan di `training/train.json` (`datasetPath`, `valDatasetPath`, `valRatio`, `splitSeed`).
   Lalu buka tab `training/train.json` dan tekan **Jalankan**. Trainer mengunggah train dan val sebagai `<nama-dataset>_train.jsonl` dan `<nama-dataset>_val.jsonl`.

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
