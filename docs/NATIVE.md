# Build native (llama.cpp) dan tes model lokal

> **Catatan migrasi (2026-11-09):** layar dan tombol di dokumen ini berasal dari UI Compose lama, yang sudah dihapus dari repo. UI Flutter (`flutter_app/`) belum memiliki bagian ini; logika di modul di bawahnya tidak berubah. Lihat [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).


## 1. Persiapan (sekali)
1. Android Studio > SDK Manager > SDK Tools: pasang **NDK (Side by side)** dan **CMake 3.22+**.
2. `./scripts/setup_native.sh` (menambah submodule llama.cpp). Disarankan `git checkout <tag>` agar API tidak berubah-ubah.
3. Tambahkan `withNative=true` ke `gradle.properties`, lalu `./gradlew :engine:assembleDebug -PwithNative`. Catatan: APK Flutter belum memuat modul engine (lihat `docs/MIGRASI_FLUTTER.md`).
4. Pakai HP **arm64 asli** (emulator x86 tidak didukung: abiFilters hanya arm64-v8a).

## 2. Jika build native gagal
API llama.cpp berubah cepat. `CMakeLists.txt` membaca `llama.h` dan menetapkan define otomatis (lihat baris
`NeuroN API defs:` di log CMake): `NEURON_OLD_FLASH_API`, `NEURON_OLD_KV_API`, `NEURON_NEW_LORA_API`.
Bagian sensitif versi lain ada di `engine/src/main/cpp/llama_compat.h`; perbaiki di sana dulu.
- Build selalu dioptimasi (-O3) walau varian Debug; tanpa itu inferensi sangat lambat.
- Log internal llama.cpp muncul di logcat dengan tag `NeuroN-llama` (filter ini saat model gagal dimuat).

## 3. Tes cepat dengan model kecil
1. Unduh GGUF kecil, mis. Qwen2.5-0.5B-Instruct Q4_K_M (~400 MB) dari Hugging Face.
2. Salin ke HP: `adb push model.gguf /sdcard/Android/data/com.neuron.engine/files/models/`
3. Di app: `engine/api.json` -> `"mode": "LOCAL"`; `model/quantization.json` -> `modelPath` = path di atas; Simpan.
4. Chat di panel bawah. Ubah `chat/params.json` / `hardware/engine.json` (threads 4-6 untuk mulai), Simpan, chat lagi.
5. LoRA hasil training: isi `model/lora.json` (path .gguf + scale).

## 4. Batas yang perlu diketahui
- Context shift aktif: prompt yang kepanjangan dipotong di tengah (awal ~128 token + pesan terbaru dipertahankan), dan saat generate penuh, setengah riwayat dibuang. Jika model tidak mendukung shift KV, generate berhenti di batas context. Pemotongan tengah memutus awalan cache, jadi prefix cache hanya mengenai bagian awal.
- Template chat: memakai template bawaan model / yang dikenali llama.cpp. Jinja bebas di `model/chat_template.jinja` belum didukung (jatuh ke ChatML).
- Prefix KV cache aktif: awalan prompt yang sama dengan permintaan sebelumnya tidak diproses ulang (lihat logcat `prefill: ... dipakai ulang`). Jika model tidak mendukung pemangkasan KV (recurrent/SWA), otomatis prefill penuh.
- `kvCacheType` selain f16 butuh `flashAttention=true`.
- `numGpuLayers` > 0 hanya berguna jika dibuild dengan `-PwithVulkan` (lihat bagian 5); tanpa itu diabaikan.
- Belum dikompilasi/diuji di perangkat.

## 5. GPU via Vulkan (opsional, BELUM diuji)
1. `./scripts/setup_native.sh --vulkan` (menambah submodule Vulkan-Headers; header bawaan NDK sering kurang baru).
2. NDK r26+ (butuh `shader-tools/glslc`), minSdk 26 sudah cukup.
3. Build: `./gradlew assembleDebug -PwithNative -PwithVulkan` (atau tambahkan `withVulkan=true` ke gradle.properties).
4. Cek di log CMake baris `Vulkan: glslc=... lib=...`, dan di logcat `NeuroN-llama` baris `ggml_vulkan: Found N devices`.
5. Di `hardware/engine.json` coba `numGpuLayers` 99 (semua layer) lalu bandingkan tok/detik dengan 0. Di banyak HP (terutama Mali) Vulkan bisa lebih lambat dari CPU atau error; jika begitu kembalikan ke 0.
6. `kvCacheType` selain f16 butuh `flashAttention=true`; kombinasi ini paling sering bermasalah di Vulkan, coba f16 dulu.
Jika build Vulkan gagal saat membuat shader (`vulkan-shaders-gen`), itu langkah host-compile bawaan llama.cpp: kirim log errornya.
