# Peta kapabilitas modul dan UI Flutter

Tabel ini membedakan kemampuan kode/backend dari ketersediaan nyata di aplikasi Flutter. **Ada di modul tidak otomatis berarti tersedia di APK.** Status Android build/native library belum dapat dianggap terverifikasi sebelum CI dan uji perangkat lulus. Peta status lengkap: [STATUS.md](STATUS.md) dan [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).

| Fitur | Modul/backend | Status UI Flutter saat ini | Batas penting |
|---|---|---|---|
| Chat dan parameter generasi | `model`, `engine`, `flutter_app/` | Chat dan pengaturan engine tersedia; Inspektur hanya mengedit subset parameter | API butuh endpoint kompatibel; release hanya mengizinkan HTTPS keluar. HTTP lokal hanya debug build. |
| Konfigurasi model/template | `project`, `engine`, `ModelDefaults` | Editor/workspace konfigurasi tersedia secara terbatas | Bukan editor bebas seluruh berkas; konfigurasi tidak setara dengan runtime setiap format model. |
| Model GGUF lokal | `engine` (llama.cpp JNI) | Pemilih model tersedia | Inferensi perlu `.so` llama.cpp yang cocok ABI/arsitektur. APK yang hanya memilih GGUF belum menjamin native runtime tersedia. |
| ONNX | Belum ada runtime ONNX terintegrasi | Tidak tersedia | Runtime `onnxruntime-genai` belum diintegrasikan; jangan nyatakan ONNX bisa dijalankan. |
| Safetensors / AWQ / GPTQ | Sebagian operasi di backend Python + llama.cpp conversion scripts | Tidak ada alur operasi konversi end-to-end di Flutter | Konversi/kuantisasi berat memerlukan server dan dependensi yang sesuai; AWQ/GPTQ belum didukung sebagai input runnable lokal. |
| Quantization | `engine`, tool llama.cpp di backend | Pemilihan model GGUF bisa dilakukan; tool quantize bukan workflow lengkap Flutter | Kompatibilitas bergantung binary, format, RAM, dan model sumber. |
| Tokenizer / vocab | Metadata project dan engine GGUF | Data konfigurasi dapat tampil di workspace | `vocab.json` hanya data project, tidak mengganti tokenizer GGUF. `special.eos` dipakai sebagai stop sequence. |
| Knowledge / RAG | `rag`, SQLite vector store, engine embed | Impor dokumen dan indexing tersedia | Embedding memerlukan engine/API yang mendukungnya; hapus file/progress terpusat belum tersedia. |
| Training remote SFT/LoRA/QLoRA/DPO | `train` Kotlin, `python/server.py`, `train_lora.py` | Dataset import/validasi, konfigurasi, job/progres, stop/sambung, ZIP dan LoRA GGUF terhubung dasar | Belum dibuild/diuji pada perangkat/server; split train/val dan grafik belum ada. ON_DEVICE masih kerangka dan binary finetune belum disertakan. |
| Hardware tuning | `hardware/engine.json`, `engine` | Konfigurasi dasar melalui workspace | Editor hardware terstruktur dan validasi kompatibilitas perangkat belum tersedia; Vulkan/OpenCL memerlukan build khusus. |
| Tools dan guardrails | `engine`, `features`, `ProjectBridge` | Toggle tool calling dan editor kata/regex tersedia | Guardrail bukan jaminan keamanan; tetap perlu validasi server-side dan human oversight. |
| Vision / TTS / STT | Sebagian kemampuan lama pada Kotlin/API | Tidak tersedia sebagai alur Flutter saat ini | Vision API belum diekspos sebagai UI attachment; vision lokal belum ada; jangan klaim tersedia hanya karena model/data class mendukungnya. |
| Server lokal OpenAI-compatible | `server`, `LocalServerService` | Halaman Server tersedia: key, port, konfirmasi, start/stop/status | Inbound masih HTTP tanpa TLS; key minimum 32 karakter dan listener dibatasi ke satu IPv4 aktif. Hanya jaringan tepercaya, jangan expose ke internet. |
| Copilot konfigurasi | `copilot`, `ProjectBridge` | Saran dan apply patch setelah ditinjau tersedia | Hanya patch file yang diizinkan; evaluasi penuh, undo/reject bertingkat belum tersedia. Kualitas bergantung provider/model. |
| API remote | `engine.RemoteApiEngine` | Base URL/model/key melalui Settings | Release memblokir HTTP keluar; pakai HTTPS. Debug build dapat memakai HTTP untuk tes lokal. |
| Library / import | `flutter_app/` | Pilih GGUF perangkat, cari/unduh HF, impor knowledge | URL langsung, cloud storage, transfer LAN, multi-select/review belum tersedia. |

## Status keamanan jaringan

Build release menyetel `usesCleartextTraffic=false`; hanya manifest varian debug memberi pengecualian HTTP. Ini membatasi koneksi aplikasi **keluar**. Server Ktor yang berjalan pada ponsel adalah koneksi **masuk** terpisah dan tetap HTTP; UI menampilkan konfirmasi risiko sebelum mulai. Karena bearer key dan isi prompt tidak terenkripsi pada server lokal, gunakan hanya di LAN/VPN tepercaya serta hentikan server setelah digunakan.
