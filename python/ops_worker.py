"""Operasi model (tanpa batas ukuran buatan; batasnya RAM/disk server).
Subcommand: download | merge_lora | merge_models | inspect | set_meta
Output: baris JSON per event, event akhir {"status":"done",...}
"""
import argparse, json, shutil, struct, subprocess, sys
from pathlib import Path


def emit(**kw):
    print(json.dumps(kw, ensure_ascii=False), flush=True)


def cmd_download(a):
    from huggingface_hub import snapshot_download  # resume otomatis, file besar dipecah per file
    p = snapshot_download(repo_id=a.repo, local_dir=a.out, token=a.token or None)
    emit(status="done", path=p)


def cmd_merge_lora(a):
    import torch
    from peft import PeftModel
    from transformers import AutoModelForCausalLM, AutoTokenizer
    emit(log="memuat model dasar")
    model = AutoModelForCausalLM.from_pretrained(a.base, torch_dtype=torch.float16, low_cpu_mem_usage=True)
    model = PeftModel.from_pretrained(model, a.adapter).merge_and_unload()
    emit(log="menyimpan (shard 5GB)")
    model.save_pretrained(a.out, max_shard_size="5GB", safe_serialization=True)
    AutoTokenizer.from_pretrained(a.base).save_pretrained(a.out)
    emit(status="done", path=a.out)


def cmd_merge_models(a):
    """Rata-rata berbobot (linear) model dengan arsitektur SAMA. SLERP/TIES/DARE: pakai mergekit."""
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    models = a.models.split(",")
    w = [float(x) for x in a.weights.split(",")]
    s = sum(w); w = [x / s for x in w]
    base = AutoModelForCausalLM.from_pretrained(models[0], torch_dtype=torch.float16, low_cpu_mem_usage=True)
    acc = {k: v.float() * w[0] for k, v in base.state_dict().items()}
    for i, m in enumerate(models[1:], start=1):
        emit(log=f"menggabungkan {m}")
        other = AutoModelForCausalLM.from_pretrained(m, torch_dtype=torch.float16, low_cpu_mem_usage=True).state_dict()
        if set(other) != set(acc):
            raise ValueError(f"Arsitektur {m} tidak sama dengan model pertama")
        for k in acc:
            acc[k] += other[k].float() * w[i]
        del other
    base.load_state_dict({k: v.half() for k, v in acc.items()})
    base.save_pretrained(a.out, max_shard_size="5GB", safe_serialization=True)
    AutoTokenizer.from_pretrained(models[0]).save_pretrained(a.out)
    emit(status="done", path=a.out)


def _gguf_value(f):
    try:
        t = f.types[0].name
        if t == "STRING":
            return bytes(f.parts[f.data[0]]).decode("utf-8")[:2000]
        if t == "ARRAY":
            return f"<array {len(f.data)} item>"
        return f.parts[f.data[0]][0].item()
    except Exception:
        return "<?>"


def cmd_inspect(a):
    p = Path(a.path)
    if p.suffix == ".gguf":
        from gguf import GGUFReader  # memetakan file (mmap), tidak memuat seluruh model
        r = GGUFReader(str(p))
        emit(status="done", kind="gguf", size=p.stat().st_size, tensors=len(r.tensors),
             meta={k: _gguf_value(f) for k, f in r.fields.items()})
        return
    total, files = 0, []
    for f in sorted(p.glob("*.safetensors")):
        with open(f, "rb") as fh:  # hanya baca header, bukan bobot
            n = struct.unpack("<Q", fh.read(8))[0]
            hdr = json.loads(fh.read(n))
        cnt = 0
        for k, v in hdr.items():
            if k == "__metadata__":
                continue
            c = 1
            for d in v["shape"]:
                c *= d
            cnt += c
        total += cnt
        files.append({"file": f.name, "params": cnt, "bytes": f.stat().st_size})
    cfg = p / "config.json"
    emit(status="done", kind="hf", params=total, files=files,
         config=json.loads(cfg.read_text()) if cfg.exists() else None)


def cmd_set_meta(a):
    scripts = Path(a.llama) / "gguf-py" / "gguf" / "scripts"
    flags = {"tokenizer.chat_template": "--chat-template", "general.name": "--general-name",
             "general.description": "--general-description"}
    if a.key in flags:  # tulis ulang file (streaming) dengan metadata baru
        subprocess.run([sys.executable, str(scripts / "gguf_new_metadata.py"), a.src, a.out, flags[a.key], a.value], check=True)
    else:  # scalar (angka/bool) diubah langsung di salinan
        shutil.copyfile(a.src, a.out)
        subprocess.run([sys.executable, str(scripts / "gguf_set_metadata.py"), a.out, a.key, a.value], check=True)
    emit(status="done", path=a.out)


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    d = sp.add_parser("download"); d.add_argument("--repo", required=True); d.add_argument("--out", required=True); d.add_argument("--token", default="")
    m = sp.add_parser("merge_lora"); m.add_argument("--base", required=True); m.add_argument("--adapter", required=True); m.add_argument("--out", required=True)
    g = sp.add_parser("merge_models"); g.add_argument("--models", required=True); g.add_argument("--weights", required=True); g.add_argument("--out", required=True)
    i = sp.add_parser("inspect"); i.add_argument("--path", required=True)
    s = sp.add_parser("set_meta"); [s.add_argument(f"--{x}", required=True) for x in ("llama", "src", "out", "key", "value")]
    a = ap.parse_args()
    try:
        globals()["cmd_" + a.cmd](a)
    except Exception as e:  # noqa
        emit(status="error", message=str(e))
        sys.exit(1)


if __name__ == "__main__":
    main()
