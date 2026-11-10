"""Pemeriksaan sumber sebelum konversi ke GGUF.
Dipanggil server.py sebelum convert_hf_to_gguf.py, supaya format yang tidak didukung gagal dengan pesan jelas.
Bisa dicoba langsung: python convert_check.py <folder-atau-file>
"""
import json
import sys
from pathlib import Path


def inspect_source(name: str) -> dict:
    """Kembalikan {'format', 'ok', 'message'}. ok = True hanya untuk safetensors yang siap dikonversi."""
    p = Path(name)
    if not p.exists():
        return {"format": "?", "ok": False, "message": f"sumber tidak ditemukan di server: {name}"}

    if p.is_file():
        ext = p.suffix.lower()
        if ext == ".gguf":
            return {"format": "GGUF", "ok": False, "message": "sudah GGUF, tidak perlu dikonversi (bisa langsung di-quantize atau dipakai)"}
        if ext == ".onnx":
            return {"format": "ONNX", "ok": False, "message": "ONNX tidak bisa dikonversi ke GGUF. Butuh runtime onnxruntime-genai (belum tersedia)."}
        return {"format": "?", "ok": False, "message": f"format file '{ext or '(tanpa ekstensi)'}' tidak dikenal; sumber harus folder model HF"}

    if any(p.glob("*.onnx")):
        return {"format": "ONNX", "ok": False,
                "message": "folder berisi .onnx: ONNX tidak bisa dikonversi ke GGUF (butuh onnxruntime-genai)."}

    cfg_path = p / "config.json"
    if not cfg_path.exists():
        return {"format": "?", "ok": False, "message": "config.json tidak ada di folder model"}
    try:
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    except (ValueError, OSError) as e:
        return {"format": "?", "ok": False, "message": f"config.json tidak bisa dibaca: {e}"}

    # Model ter-kuantisasi di repo HF ditandai lewat quantization_config.
    qc = cfg.get("quantization_config") or {}
    method = str(qc.get("quant_method", "")).lower()
    if method in ("awq", "gptq"):
        fmt = method.upper()
        return {"format": fmt, "ok": False,
                "message": f"model {fmt} (ter-kuantisasi) tidak bisa dikonversi langsung ke GGUF. Unduh versi FP16/BF16 (safetensors) dari repo asalnya, lalu konversi."}
    if method:
        return {"format": method.upper(), "ok": False,
                "message": f"metode kuantisasi '{method}' belum diverifikasi untuk konversi. Gunakan versi FP16/BF16."}

    if any(p.glob("*.safetensors")):
        dtype = str(cfg.get("torch_dtype") or cfg.get("dtype") or "?")
        return {"format": "SAFETENSORS", "ok": True, "message": f"safetensors siap dikonversi (dtype {dtype})"}
    return {"format": "?", "ok": False, "message": "tidak ditemukan file .safetensors di folder model"}


if __name__ == "__main__":
    print(json.dumps(inspect_source(sys.argv[1]), ensure_ascii=False, indent=2))
