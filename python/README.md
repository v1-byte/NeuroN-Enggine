# NeuroN Trainer (Python)

> **Catatan migrasi (2026-11-09):** layar dan tombol di dokumen ini berasal dari UI Compose lama, yang sudah dihapus dari repo. UI Flutter (`flutter_app/`) belum memiliki bagian ini; logika di modul di bawahnya tidak berubah. Lihat [MIGRASI_FLUTTER.md](../docs/MIGRASI_FLUTTER.md).

Server edit/training yang dipanggil APK lewat HTTP. Jalankan di PC/laptop/server (idealnya GPU NVIDIA).

    python -m venv .venv && source .venv/bin/activate
    pip install -r requirements.txt
    NEURON_API_KEY=rahasia uvicorn server:app --host 0.0.0.0 --port 8001

Di APK: tab `training/train.json` -> isi `remoteTrainerUrl` = http://IP_PC:8001, target = REMOTE_SERVER.

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
Set `LLAMA_CPP_DIR` (clone llama.cpp, build `llama-quantize`). Di APK: tab `model/ops.json` -> pilih `op` -> Jalankan.
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
