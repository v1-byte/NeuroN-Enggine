# Peta kapabilitas modul dan UI Flutter

Tabel ini membedakan kemampuan kode/backend dari ketersediaan nyata di aplikasi Flutter. **Ada di modul tidak otomatis berarti tersedia di APK.** Status Android build/native library belum dapat dianggap terverifikasi sebelum CI dan uji perangkat lulus. Peta status lengkap: [STATUS.md](STATUS.md) dan [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).

| Fitur | Modul/backend | Status UI Flutter saat ini | Batas penting |
|---|---|---|---|
| Chat dan parameter generasi | `model`, `engine`, `flutter_app/` | Chat dan pengaturan engine tersedia; Inspektur hanya mengedit subset parameter | API butuh endpoint kompatibel; release hanya mengizinkan HTTPS keluar. HTTP lokal hanya debug build. |
| Konfigurasi model/template | `project`, `engine`, `ModelDefaults` | Editor/workspace konfigurasi tersedia secara terbatas | Bukan editor bebas seluruh berkas; konfigurasi tidak setara dengan runtime setiap format model. |
| Edit metadata GGUF (nama, template chat, token khusus) | `engine/GgufMeta.kt`, `ProjectBridge` (`ggufInspect`/`ggufSave`), `gguf_editor.dart` | Tersedia di Lainnya → Editor GGUF | Hanya header metadata; bobot tidak diubah. Hasil berupa salinan baru (butuh ruang sebesar model). Array (token), arsitektur, dan key bentuk tensor dikunci. Template chat hanya efektif bila dikenali llama.cpp. Belum dikompilasi/diuji di perangkat. |
| Model GGUF lokal | `engine` (llama.cpp JNI) | Pemilih model tersedia | Inferensi perlu `.so` llama.cpp yang cocok ABI/arsitektur. APK yang hanya memilih GGUF belum menjamin native runtime tersedia. |
| ONNX | Belum ada runtime ONNX terintegrasi | Tidak tersedia | Runtime `onnxruntime-genai` belum diintegrasikan; jangan nyatakan ONNX bisa dijalankan. |
| Safetensors / AWQ / GPTQ | Sebagian operasi di backend Python + llama.cpp conversion scripts | Tidak ada alur operasi konversi end-to-end di Flutter | Konversi/kuantisasi berat memerlukan server dan dependensi yang sesuai; AWQ/GPTQ belum didukung sebagai input runnable lokal. |
| Quantization | `engine`, tool llama.cpp di backend, `weight_ops_page.dart` | Lainnya → Ubah bobot: pilih model lokal dan format; sumber terkuantisasi butuh saklar kuantisasi ulang | Berjalan di server HTTPS (bukan di HP); hasil model GGUF baru. Kompatibilitas bergantung binary, format, RAM, dan model sumber. Belum dikompilasi/diuji di perangkat. |
| Tanam LoRA ke model | `python/server.py` (`MERGE_LORA_GGUF`), `weight_ops_page.dart` | Lainnya → Ubah bobot | Butuh `llama-export-lora` di server; paling andal pada model dasar F16/F32. Belum diuji dengan llama.cpp nyata. |
| Gabung model | `python/ops_worker.py` (`merge_models`), `TrainingBridge.runModelPipeline`, `weight_ops_page.dart` | Lainnya → Ubah bobot | Rata-rata linear model berarsitektur sama (bukan SLERP/TIES). Butuh RAM server sekitar 4-5x ukuran model FP16. Belum diuji dengan model nyata. |
| Tokenizer / vocab | Metadata project dan engine GGUF | Data konfigurasi dapat tampil di workspace | `vocab.json` hanya data project, tidak mengganti tokenizer GGUF. `special.eos` dipakai sebagai stop sequence. |
| Knowledge / RAG | `rag`, SQLite vector store, engine embed | Impor dokumen dan indexing tersedia | Embedding memerlukan engine/API yang mendukungnya; hapus file/progress terpusat belum tersedia. |
| Training remote SFT/LoRA/QLoRA/DPO | `train` Kotlin, `python/server.py`, `train_lora.py` | Dataset import/validasi, konfigurasi, job/progres, stop/sambung, ZIP dan LoRA GGUF terhubung dasar | Belum dibuild/diuji pada perangkat/server; split train/val dan grafik belum ada. ON_DEVICE masih kerangka dan binary finetune belum disertakan. |
| Privasi per model (`privacy.json`) | `model/PrivacyPolicy.kt`, `ProjectBridge` (`privacy*`), `privacy_dialog.dart` | Lainnya → Fitur → Edit privasi model | Skema `privacy.json` dari pemilik model belum dikunci; parser menebak dari nama kunci. Lihat [PRIVACY.md](PRIVACY.md). Belum dikompilasi/diuji di perangkat |
| Hardware tuning | `hardware/engine.json`, `engine` | Konfigurasi dasar melalui workspace | Editor hardware terstruktur dan validasi kompatibilitas perangkat belum tersedia; Vulkan/OpenCL memerlukan build khusus. |
| Tools dan guardrails | `engine`, `features`, `ProjectBridge` | Toggle tool calling dan editor kata/regex tersedia | Guardrail bukan jaminan keamanan; tetap perlu validasi server-side dan human oversight. |
| Vision / TTS / STT | Sebagian kemampuan lama pada Kotlin/API | Tidak tersedia sebagai alur Flutter saat ini | Vision API belum diekspos sebagai UI attachment; vision lokal belum ada; jangan klaim tersedia hanya karena model/data class mendukungnya. |
| Server lokal OpenAI-compatible | — | **Dihapus (2026-11-24)** | Mode API dan server lokal sudah dihapus dari repo; tidak ada listener HTTP di ponsel. Entri historis di STATUS.md hanya catatan sejarah |
| Copilot konfigurasi | `copilot`, `ProjectBridge` | Saran dan apply patch setelah ditinjau tersedia | Hanya patch file yang diizinkan; evaluasi penuh, undo/reject bertingkat belum tersedia. Kualitas bergantung provider/model. |
| Library / import | `flutter_app/` | Pilih GGUF perangkat, cari/unduh HF, impor knowledge | URL langsung, cloud storage, transfer LAN, multi-select/review belum tersedia. |

## Status keamanan jaringan

Build release menyetel `usesCleartextTraffic=false`; hanya manifest varian debug memberi pengecualian HTTP. Ini membatasi koneksi aplikasi **keluar** (Hugging Face dan server pelatih Python). Server lokal masuk sudah dihapus, jadi tidak ada listener HTTP di ponsel.
