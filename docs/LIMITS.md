# Batas ukuran: apa yang dibatasi aplikasi, apa yang dibatasi hardware

## Aplikasi (tidak ada batas buatan)
- Unggah/unduh model di-stream per potongan (tidak dimuat ke RAM) dan bisa dilanjutkan (HTTP Range).
- Server Python menyimpan upload ke disk bertahap; tidak ada MAX_SIZE.
- Simpan model di `getExternalFilesDir()` (ruang besar). Kartu SD berformat FAT32 membatasi 4 GB per file.

## Hardware (tidak bisa dihilangkan oleh software)
| Aksi | Batas | Catatan |
|---|---|---|
| Jalankan model di HP | RAM HP | Kasar: Q4 ~0,6 GB per 1 miliar parameter. 7B Q4 ~4-5 GB: pas di HP 8-12 GB, pelan. 70B: tidak bisa |
| Inspect GGUF/safetensors | hampir tidak ada | hanya membaca header/metadata |
| Konversi, kuantisasi, merge | RAM + disk server | kira-kira sebesar model; merge model = ~1,5-2x |
| Training | VRAM GPU server | QLoRA 7B ~ 10-16 GB VRAM |
| Edit teks di editor APK | memori UI | file teks puluhan MB (vocab) berat di UI (Compose lama dan Flutter sama-sama memuat seluruh teks); TODO: viewer berhalaman |

## Cara menangani model besar
Model di server (PC/GPU) -> APK memakai `RemoteApiEngine` untuk chat dan `ModelOpsClient` untuk mengubahnya.
