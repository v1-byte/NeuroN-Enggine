# Layar Latih: Training remote, progres, sambung job, dan unduh hasil (langkah 19)

> **Status UI Flutter (2026-11-10):** workflow training remote tahap awal kini tersedia: konfigurasi, impor/validasi dataset, start, polling progres/log, stop/sambung, unduh ZIP, dan unduh LoRA GGUF. Belum ada split train/val atau grafik loss, ON_DEVICE belum tersedia, dan alur belum dibuild/diuji di perangkat/server. API key disimpan melalui `SecretStore`, bukan di `training/train.json`.


## 1. Membuka layar
Buka **Lainnya → Training** atau **Import Center → Dataset training**.

## 2. Syarat sebelum Latih
- Atur URL server dan model dasar. Build rilis memerlukan HTTPS; HTTP hanya untuk debug/LAN tepercaya.
- Pilih metode dan dataset JSONL/JSON/CSV; dataset harus memiliki nol error validasi. File disalin ke direktori privat app.
- API key bersifat opsional bila server tidak memerlukannya; bila disediakan, key disimpan terenkripsi di `SecretStore`.

## 3. Alur
1. **Mulai training** mengunggah dataset bersih sebagai data train, membuat job remote, lalu memantau progresnya.
2. **Progres/log** diperbarui melalui polling bridge lokal; maksimal 300 baris log ditampilkan.
3. Setelah status **done**, unduh hasil:
   - **Adapter (.zip)** disimpan di `getExternalFilesDir("adapters")/<job>.zip`.
   - **LoRA (.gguf)** disimpan di `getExternalFilesDir("models")/<job>-lora.gguf`. Server mengonversi adapter dengan llama.cpp, jadi server perlu `LLAMA_CPP_DIR`.
4. **Unduh & pakai LoRA GGUF** menyimpan file di folder models dan menulis path-nya ke `model/lora.json`; konversi memerlukan `LLAMA_CPP_DIR` pada server.

## 4. Stop dan sambung
- **Stop** mengirim permintaan cancel ke server. Periksa status server sesudahnya karena pembatalan bergantung pada proses trainer.
- Masukkan **ID job** yang tampil di kartu Job lalu tekan **Sambung** untuk membaca event server kembali setelah app ditutup.

## 5. Batasan
- Dataset sekarang langsung dipakai sebagai train; split validation dan grafik loss belum tersedia.
- Penyambungan mengandalkan job/event yang masih disimpan oleh proses server Python; server dapat mengirim ulang log lama.
- Endpoint adapter ZIP/GGUF dan kompatibilitas metode tetap harus diuji terhadap versi server aktual.
- Implementasi belum dikompilasi atau diuji di perangkat Android maupun server remote.
