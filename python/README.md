# NeuroN Trainer (Python)

> **Status UI Flutter (2026-11-10):** halaman Training dan operasi model masih placeholder/tidak terhubung ke API backend. Instruksi di bawah menjelaskan server dan endpoint yang tersedia, bukan alur yang dapat dimulai dari layar Flutter. Lihat [MIGRASI_FLUTTER.md](../docs/MIGRASI_FLUTTER.md).

Backend edit/training untuk dijalankan di PC/laptop/server (idealnya GPU NVIDIA). UI Training/Model Ops Flutter belum mengorkestrasi job tersebut.

    python -m venv .venv && source .venv/bin/activate
    pip install -r requirements.txt
    NEURON_API_KEY='ganti-dengan-random-secret' uvicorn server:app --host 127.0.0.1 --port 8001

API bisa diuji langsung dari klien yang diizinkan. APK debug dapat memakai HTTP lokal; APK release hanya mengizinkan HTTPS. Untuk produksi, publikasikan backend di balik reverse proxy TLS. File `training/train.json` dapat memuat `remoteTrainerApiKey` plaintext bila diisi manual; jangan commit nilai rahasia.

| Method | CPU | GPU |
|---|---|---|
| LORA | model <=0.5B, lambat | ya |
| QLORA | tidak | ya (CUDA) |
| DPO | model kecil, lambat | ya |
| FULL_FINETUNE | tidak | butuh VRAM besar |
| RLHF | belum didukung | - |

Alur hasil: adapter -> `POST /convert/lora/{job}` (set LLAMA_CPP_DIR) -> `adapter.gguf` -> dimuat llama.cpp di HP.
Python TIDAK dijalankan di dalam APK: PyTorch/PEFT/bitsandbytes tidak tersedia untuk Android. Kotlin hanya memanggil API ini.

## Operasi model
Set `LLAMA_CPP_DIR` (clone llama.cpp, build `llama-quantize`). Endpoint operasi model tersedia pada backend Python, tetapi UI Flutter saat ini tidak memiliki layar untuk memilih operasi dan mengelola hasilnya.
Op: DOWNLOAD_HF, CONVERT_TO_GGUF, QUANTIZE, MERGE_LORA, MERGE_MODELS (arsitektur sama; untuk SLERP/TIES pakai mergekit), INSPECT, SET_GGUF_META.
Belum diuji: nama argumen script gguf-py dapat berbeda antar versi llama.cpp.

## Smoke test (tanpa server berjalan)
```bash
python python/tests/smoke_server.py
```
Memeriksa sintaks dan nama tak terdefinisi di semua berkas Python, mengimpor `server.py`, lalu menguji
route, auth, validasi path, pemeriksaan konversi, dan wiring validasi (`val_dataset`). Training dan konversi
tidak dijalankan: `spawn()` diganti pencatat.

Jika fastapi & pydantic tidak terpasang, skrip memakai stub di `tests/_stubs/` (hanya meniru bentuk API).
Dengan stub, perilaku HTTP asli TIDAK diuji.

CI memasang dependency API ringan (bukan stack training GPU) dan menjalankan mode nyata:
```bash
python -m pip install -r python/requirements-test.txt
python python/tests/smoke_server.py
```
Mode nyata menguji autentikasi dan upload melalui FastAPI `TestClient`.

## Uji HTTP sungguhan (perlu dependensi terpasang)
```bash
pip install -r python/requirements.txt
cd python
NEURON_API_KEY=rahasia NEURON_DATA=./data uvicorn server:app --host 127.0.0.1 --port 8001
curl -H "X-API-Key: rahasia" http://127.0.0.1:8001/health
curl -H "X-API-Key: rahasia" -H "Content-Type: application/json" \
  -d '{"op":"CONVERT_TO_GGUF","params":{"source":"tidak-ada","output":"x.gguf"}}' http://127.0.0.1:8001/ops
```
Respons pertama harus `{"status":"ok","llama_cpp":false}`. Respons kedua harus HTTP 400 dengan pesan "sumber tidak ditemukan".

## Batas operasional dan deployment

- Default batas berkas: dataset **2 GiB**, model **128 GiB**. Atur `NEURON_MAX_DATASET_UPLOAD_BYTES` dan `NEURON_MAX_MODEL_UPLOAD_BYTES` ke batas yang sesuai kapasitas penyimpanan.
- Default hanya **1 job aktif** dan batas waktu job **24 jam**. Konfigurasi melalui `NEURON_MAX_ACTIVE_JOBS` dan `NEURON_MAX_JOB_SECONDS`. Kapasitas job dihitung per proses server; jalankan satu worker Uvicorn kecuali ada antrean/koordinator lintas-worker yang disiapkan.
- Unggah berkas tetap membutuhkan batas body di reverse proxy/gateway karena multipart dapat di-buffer sebelum handler aplikasi memeriksa ukuran. Terapkan juga TLS, firewall, rate limiting, quota/retensi disk, rotasi API key dan monitoring di deployment.
- Jangan expose Uvicorn langsung ke internet. Ikat ke `127.0.0.1` di belakang reverse proxy TLS, atau batasi jaringan dengan firewall/VPN. API key tidak menggantikan TLS.
- Limit upload adalah per request; administrator tetap perlu menetapkan quota total storage dan kebijakan retensi jobs/models.
