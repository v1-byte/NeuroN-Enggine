# Latih on-device (langkah 20)

> **Catatan migrasi (2026-11-09):** layar dan tombol di dokumen ini berasal dari UI Compose lama, yang sudah dihapus dari repo. UI Flutter (`flutter_app/`) belum memiliki bagian ini; logika di modul di bawahnya tidak berubah. Lihat [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).


## 0. Status jujur
- Trainer ON_DEVICE memanggil **binary finetune llama.cpp** sebagai proses terpisah. Binary itu **belum ada di repo**. Sumber llama.cpp ditambahkan lewat `scripts/setup_native.sh` saat build, dan saya tidak bisa memeriksanya dari sini.
- Nama flag CLI (`--model-base`, `--train-data`, `--lora-out`, dll.) dan format baris log **belum diverifikasi**. Keduanya harus dicocokkan dengan build yang Anda pakai.
- Bagian yang sudah berjalan tanpa binary: preflight, konversi dataset, pembentukan argumen, dan layar.
- Memuat adapter ke engine sudah ada sebelumnya: `loraPath` masuk ke `EngineFactory.key`, sehingga engine dimuat ulang saat adapter berubah.

## 1. Menyiapkan binary (belum diuji)
1. Gunakan submodule llama.cpp yang sama dengan `docs/NATIVE.md`.
2. Build contoh finetune untuk Android arm64 memakai NDK toolchain. Flag CMake bergantung pada versi llama.cpp, jadi lihat `CMakeLists.txt` di submodule. Umumnya:
   `cmake -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 ...`
3. Ambil executable hasilnya dan salin ke:
   `flutter_app/android/app/src/main/jniLibs/arm64-v8a/libllamafinetune.so`
   Nama berakhiran `.so` dipakai agar Android mengekstraknya ke `nativeLibraryDir`. `useLegacyPackaging true` sudah ada di `flutter_app/android/app/build.gradle`.
4. Cek flag yang didukung build itu: `libllamafinetune.so --help` (dari terminal di laptop dengan build desktop, atau lewat `adb shell`).
5. Sesuaikan `training/train.json` → `onDeviceArgs` dan `onDeviceLossRegex` dengan flag dan format log yang benar.
   Default di kode hanya contoh.

## 2. Placeholder pada `onDeviceArgs`
| Placeholder | Isi |
|---|---|
| `{base}` | `model/quantization.json` → `modelPath` |
| `{train}` | korpus `train.txt` yang dibuat dari dataset |
| `{out}` | `lora.gguf` di folder kerja (`filesDir/ondevice/od-<waktu>/`) |
| `{epochs}`, `{iters}`, `{batch}` | epoch, total langkah, batch |
| `{rank}`, `{alpha}`, `{lr}` | `loraRank`, `loraAlpha`, `learningRate` |
| `{threads}`, `{ctx}` | `hardware/engine.json` → `threads`, `chat/params.json` → `contextLength` |

Argumen dipisah spasi. Path tidak boleh mengandung spasi.

## 3. Preflight (di layar Latih)
Latih dikunci bila ada error berikut:
- target bukan ON_DEVICE, atau metode bukan **LORA**. QLoRA, DPO, dan full finetune tidak didukung di perangkat.
- binary tidak ditemukan atau tidak bisa dijalankan.
- model dasar tidak ditemukan, atau `quantization` bukan **F16 atau F32**. Asumsi ini konservatif: pelatihan LoRA pada bobot ter-kuantisasi belum diverifikasi di sini.
- dataset train belum ada (buat split di 📚 Data).
- jumlah langkah melebihi `onDeviceMaxSteps`.

Peringatan (tidak mengunci):
- RAM bebas kurang dari perkiraan 3× ukuran model.
- val dipilih, tetapi tidak dipakai di perangkat.

## 4. Format korpus
Dataset JSONL diubah menjadi teks dengan format:
```
### Instruction:
<pertanyaan>

### Response:
<jawaban>
```
**Ini tidak mengikuti template chat model.** Adapter paling efektif bila chat juga memakai format yang sama. Untuk format chat model yang sebenarnya, gunakan trainer REMOTE (server), yang memakai `apply_chat_template`.

## 5. Memakai adapter
Setelah status **selesai**, tampil path `lora.gguf` di kartu Hasil. Tekan **Pakai sebagai LoRA di model**. Ini menulis `model/lora.json` (`loraPath`). Chat berikutnya memuat ulang engine dengan adapter.

## 6. Batasan
- **Tidak ada resume.** Stop menghentikan proses, dan hasil parsial dibuang.
- **Beban CPU dan panas tinggi.** Training lama bisa memanaskan HP dan menguras baterai. Mulai dengan dataset kecil dan epoch 1.
- **Logging hanya lewat stdout.** Jika binary menulis progres ke file, parsing tidak akan menangkapnya.
- **Format output harus didukung engine.** Adapter harus berupa GGUF LoRA yang dikenali `nativeLoadLora` (`NEURON_NEW_LORA_API`).
- **Belum dikompilasi dan belum diuji** di perangkat.
