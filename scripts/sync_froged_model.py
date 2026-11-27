#!/usr/bin/env python3
"""Refresh a lock manifest for the public Froged N1 GGUF repository.

The binary stays on Hugging Face; this repository tracks the selected file,
revision, size, and LFS SHA-256 so builds and reviewers have reproducible
metadata without committing a large model file to GitHub.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

QUANT_ORDER = ("Q4_K_M", "Q4_K_S", "Q4_0", "Q5_K_M", "Q3_K_M", "Q8_0")


def get_json(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "NeuroN-Engine-model-sync/1.0"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def choose_gguf(files: list[dict]) -> dict:
    files = [
        item for item in files
        if str(item.get("path", "")).lower().endswith(".gguf")
        and "mmproj" not in str(item.get("path", "")).lower()
        and "imatrix" not in str(item.get("path", "")).lower()
        and "-of-" not in str(item.get("path", "")).lower()
    ]
    if not files:
        raise RuntimeError("No complete GGUF file found in the model repository")
    for quant in QUANT_ORDER:
        for item in files:
            if quant.lower() in str(item.get("path", "")).lower():
                return item
    return sorted(files, key=lambda item: item.get("size") or 0)[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default="bytecode66/Froged_N1")
    parser.add_argument("--out", default="model/froged-n1-model-lock.json")
    args = parser.parse_args()

    model = get_json(f"https://huggingface.co/api/models/{args.repo}")
    revision = model.get("sha") or "main"
    tree = get_json(f"https://huggingface.co/api/models/{args.repo}/tree/{revision}?recursive=true")
    selected = choose_gguf(tree)
    filename = selected["path"]
    lfs = selected.get("lfs") or {}
    lock = {
        "schema": 1,
        "repo": args.repo,
        "revision": revision,
        "file": filename,
        "bytes": selected.get("size"),
        "sha256": lfs.get("oid"),
        "download_url": f"https://huggingface.co/{args.repo}/resolve/{revision}/{filename}?download=true",
        "selection_policy": list(QUANT_ORDER),
        "binary_storage": "Hugging Face; not committed to GitHub",
    }
    if not lock["bytes"] or not lock["sha256"]:
        raise RuntimeError("Selected GGUF is missing size or LFS SHA-256 metadata")
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"repo": args.repo, "revision": revision, "file": filename, "bytes": selected.get("size"), "sha256": lfs.get("oid")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
