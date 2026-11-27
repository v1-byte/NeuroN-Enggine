# Format model dan jalur konversi (langkah 23)

## 1. Matriks
| Format sumber | Jalan langsung di HP | Konversi di server | Catatan |
|---|---|---|---|
| GGUF | Ya | Tidak perlu | Bisa di-quantize (QUANTIZE) atau dipakai langsung |
| SAFETENSORS (FP16/BF16) | Tidak | **Ya**, CONVERT_TO_GGUF | Jalur utama. Folder HF berisi `config.json` dan `*.safetensors` |
| SAFETENSORS (FP32) | Tidak | Ya | Hasilnya besar. Lebih baik unduh FP16 bila tersedia |
| AWQ / GPTQ | Tidak | **Tidak langsung** | Ditolak server. Unduh versi FP16/BF16 dari repo asalnya, lalu konversi |
| ONNX | Tidak | **Tidak** | Butuh runtime onnxruntime-genai, yang belum diintegrasikan |

Engine lokal (mode LOCAL) menolak format selain GGUF dengan pesan yang menyebut langkah perbaikannya.
Mode API tidak terpengaruh, karena model berjalan di server.

## 2. Pemeriksaan di server
Sebelum `convert_hf_to_gguf.py` dijalankan, server memeriksa sumber (`python/convert_check.py`):
- `quantization_config.quant_method` = `awq` atau `gptq` → ditolak.
- Metode kuantisasi lain (mis. bitsandbytes, fp8) → ditolak dengan pesan "belum diverifikasi". Pakai versi FP16/BF16.
- Ada file `.onnx` → ditolak.
- File `.gguf` yang dimasukkan sebagai sumber → ditolak, karena sudah GGUF.
- Folder tanpa `config.json` atau tanpa `.safetensors` → ditolak.

Penolakan memakai HTTP 400 dengan pesan yang bisa langsung dibaca di panel Log.

Uji pemeriksaan tanpa server:
```bash
python python/convert_check.py /path/ke/folder-model
```

## 3. Alur konversi (SAFETENSORS → GGUF → Q4_K_M)
1. Unduh model FP16 dari Hugging Face ke server lewat operasi DOWNLOAD_HF, atau salin manual ke folder data server.
2. Jalankan CONVERT_TO_GGUF dengan `outtype` `f16` (atau `bf16`, `q8_0`).
3. Jalankan QUANTIZE ke `Q4_K_M` memakai `llama-quantize` dari build llama.cpp server.
4. Ambil file `.gguf` hasilnya dari server (`GET /models/<nama>`) dengan curl.
5. Salin ke folder models di HP: `/sdcard/Android/data/com.neuron.engine/files/models/`
   atau `adb push`.
6. Isi `model/quantization.json`: `modelPath`, `format` = `GGUF`, `quantization` = `Q4_K_M`.
   Engine menolak bila `format` bukan GGUF, dan `quantization` dipakai untuk pemeriksaan preflight training (F16/F32).

## 4. Batasan
- **AWQ dan GPTQ tidak didukung langsung.** Dequantisasi ke FP16 belum diimplementasikan, karena API library-nya belum saya verifikasi.
- **ONNX belum dijalankan.** Roadmap menyebut onnxruntime-genai. Itu runtime dan engine baru, belum ada di kode.
- **Pemeriksaan hanya membaca config dan nama file.** Konversi tetap bisa gagal di `convert_hf_to_gguf.py` untuk arsitektur yang belum didukung llama.cpp.
- **Belum diuji dengan model nyata** di server. Logika pemeriksaan sudah diuji dengan folder contoh.
