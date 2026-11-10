# Layar Latih: Latih, grafik loss, sambung job, dan unduh hasil (langkah 19)

> **Catatan migrasi (2026-11-09):** layar dan tombol di dokumen ini berasal dari UI Compose lama, yang sudah dihapus dari repo. UI Flutter (`flutter_app/`) belum memiliki bagian ini; logika di modul di bawahnya tidak berubah. Lihat [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).


## 1. Membuka layar
Di editor, buka `training/train.json` lalu tekan **Latih →**. Tombol Jalankan di tab itu sudah tidak ada lagi,
supaya hanya ada satu jalur untuk memulai training.

## 2. Syarat sebelum Latih
- `target` = `REMOTE_SERVER` dan `remoteTrainerUrl` terisi. `ON_DEVICE` belum tersedia (langkah 20).
- `datasetPath` sudah terisi. Caranya: buka **📚 Data** lalu buat split.
- Tidak ada perubahan belum disimpan di editor. Tombol Latih dikunci bila ada.

## 3. Alur
1. **Latih** mengunggah train (dan val bila ada) sebagai `<nama-dataset>_train.jsonl` dan `<nama-dataset>_val.jsonl`,
   lalu memulai job di server dan memantau progresnya.
2. **Grafik loss** menggambar loss train (hijau) dan eval loss (oranye). Eval loss hanya ada bila val dipakai.
3. **Log** menampilkan 300 baris terakhir.
4. Setelah status **selesai**, unduh hasil:
   - **Adapter (.zip)** disimpan di `getExternalFilesDir("adapters")/<job>.zip`.
   - **LoRA (.gguf)** disimpan di `getExternalFilesDir("models")/<job>-lora.gguf`. Server mengonversi adapter dengan llama.cpp, jadi server perlu `LLAMA_CPP_DIR`.
5. **Pakai sebagai LoRA di model** menulis path LoRA ke `model/lora.json` (`loraPath`). Engine dimuat ulang dengan adapter itu saat chat berikutnya.

## 4. Stop dan sambung
- **Stop** berhenti memantau dan mengirim perintah cancel ke server. Job tetap bisa dicek di server.
- Jika app ditutup saat training berjalan, job tetap jalan di server. Masukkan **ID job** di kartu Job, lalu tekan **Sambung**.
  ID job tampil di layar setelah Latih dimulai. Simpan ID ini bila perlu.

## 5. Batasan
- **Riwayat setelah sambung bergantung pada server.** Layar menampilkan event yang dikirim server saat disambung. Apakah server mengirim ulang event lama belum diverifikasi.
- **Grafik tidak disimpan** setelah app ditutup. Setelah sambung, grafik dibangun ulang dari event yang diterima.
- **Satu job dipantau sekali waktu.** Mulai job baru hanya bila tidak ada yang sedang berjalan.
- **Belum dikompilasi dan belum diuji** di perangkat maupun di server.
