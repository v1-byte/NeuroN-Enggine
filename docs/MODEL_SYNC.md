# Sinkronisasi model Froged N1

Repo ini memakai `bytecode66/Froged_N1` sebagai sumber model GGUF. Aplikasi sudah memilih file GGUF secara dinamis dari daftar file Hugging Face; workflow `.github/workflows/sync-froged-model.yml` memeriksa repo tersebut setiap hari atau saat dijalankan manual.

Workflow memperbarui `model/froged-n1-model-lock.json` jika revision, nama file, ukuran, atau SHA-256 LFS model berubah. Manifest lock berisi URL unduhan, revision, ukuran, dan checksum sehingga perubahan model dapat ditinjau melalui commit GitHub.

Binary GGUF tidak disimpan di GitHub. File model sekitar ratusan MB melampaui batas file Git biasa dan akan membuat clone aplikasi berat. Binary tetap diunduh oleh Model Hub dari Hugging Face, lalu diverifikasi oleh alur unduhan aplikasi bila checksum tersedia.

## Menjalankan manual

1. Buka tab **Actions** di GitHub.
2. Pilih **Sync Froged N1 model metadata**.
3. Tekan **Run workflow** pada branch `main`.
4. Periksa perubahan `model/froged-n1-model-lock.json`.

Workflow tidak membutuhkan PAT pribadi. `GITHUB_TOKEN` bawaan Actions dipakai untuk commit metadata; PAT pengguna tidak boleh dimasukkan ke source code, workflow, atau secret yang tidak diperlukan.
