"""NeuroN Trainer: dataset, training, dan operasi model. Dipanggil APK lewat HTTP.
Jalankan di localhost: NEURON_API_KEY=<secret> LLAMA_CPP_DIR=/path/llama.cpp uvicorn server:app --host 127.0.0.1 --port 8001
Upload memiliki batas yang dapat dikonfigurasi; deployment wajib membatasi body di reverse proxy juga.
"""
import asyncio, hmac, json, os, re, shutil, signal, subprocess, sys, threading, uuid
from pathlib import Path

from fastapi import Depends, FastAPI, File, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel, Field

HERE = Path(__file__).parent
DATA = Path(os.environ.get("NEURON_DATA", "./data")).resolve()
for _d in ("datasets", "jobs", "models"):
    (DATA / _d).mkdir(parents=True, exist_ok=True)
API_KEY = os.environ.get("NEURON_API_KEY", "")
if not API_KEY:
    raise RuntimeError("NEURON_API_KEY wajib diisi. Server menolak berjalan tanpa API key.")
LLAMA = os.environ.get("LLAMA_CPP_DIR", "")


def positive_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    try:
        value = int(raw) if raw is not None else default
    except ValueError as exc:
        raise RuntimeError(f"{name} harus berupa integer positif") from exc
    if value <= 0:
        raise RuntimeError(f"{name} harus berupa integer positif")
    return value


# Batas dapat disesuaikan untuk deployment, tetapi proxy di depan API juga wajib
# membatasi ukuran body karena multipart dapat di-buffer sebelum handler berjalan.
MAX_DATASET_UPLOAD_BYTES = positive_env("NEURON_MAX_DATASET_UPLOAD_BYTES", 2 * 1024**3)
MAX_MODEL_UPLOAD_BYTES = positive_env("NEURON_MAX_MODEL_UPLOAD_BYTES", 128 * 1024**3)
MAX_ACTIVE_JOBS = positive_env("NEURON_MAX_ACTIVE_JOBS", 1)
MAX_JOB_SECONDS = positive_env("NEURON_MAX_JOB_SECONDS", 24 * 60 * 60)


def auth(x_api_key: str = Header(default="")):
    if not hmac.compare_digest(x_api_key.encode(), API_KEY.encode()):
        raise HTTPException(401, "API key salah")


app = FastAPI(title="NeuroN Trainer", dependencies=[Depends(auth)])
JOBS: dict[str, subprocess.Popen] = {}
JOBS_LOCK = threading.Lock()


# ---------- util ----------
def safe_name(n: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", Path(n).name)


def model_path(name: str) -> Path:
    root = (DATA / "models").resolve()
    p = (root / name).resolve()
    if p != root and root not in p.parents:
        raise HTTPException(400, "path tidak valid")
    return p


def out_path(name: str) -> Path:
    p = model_path(name)
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


HF_REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?")


def hf_repo(name: str) -> str:
    """Hanya id repo HF yang valid; path absolut, '..', atau path lokal di luar folder models ditolak."""
    if not HF_REPO.fullmatch(name) or ".." in name or os.path.exists(name):
        raise HTTPException(400, "source harus nama model di server, job id adapter, atau id repo HF")
    return name


def resolve(name: str) -> str:
    """nama model di server | job id adapter | id repo HF. Selain itu ditolak (400)."""
    try:
        m = model_path(name)
        if m.exists() and m != (DATA / "models").resolve():
            return str(m)
    except HTTPException:
        pass
    if re.fullmatch(r"[0-9a-f]{8}", name):
        a = DATA / "jobs" / name / "out" / "adapter"
        if a.exists():
            return str(a)
    return hf_repo(name)


def need(p: dict, *keys):
    for k in keys:
        if not p.get(k):
            raise HTTPException(400, f"parameter '{k}' wajib")


def need_llama() -> Path:
    if not LLAMA:
        raise HTTPException(500, "set env LLAMA_CPP_DIR ke folder llama.cpp")
    return Path(LLAMA)


async def save_stream(file: UploadFile, dest: Path, max_bytes: int):
    tmp = dest.with_name(dest.name + ".part")
    total = 0
    try:
        with open(tmp, "wb") as out:
            while chunk := await file.read(1 << 20):
                total += len(chunk)
                if total > max_bytes:
                    raise HTTPException(413, f"Berkas melebihi batas {max_bytes} byte")
                out.write(chunk)
        tmp.replace(dest)
        return total
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def spawn(cmd: list, jid: str):
    jdir = DATA / "jobs" / jid
    with JOBS_LOCK:
        active = sum(1 for proc in JOBS.values() if proc.poll() is None)
        if active >= MAX_ACTIVE_JOBS:
            raise HTTPException(503, "Kapasitas job penuh; coba lagi setelah job aktif selesai")
        jdir.mkdir(parents=True, exist_ok=True)
        with open(jdir / "log.txt", "w", encoding="utf-8") as log:
            proc = subprocess.Popen(
                [str(c) for c in cmd], stdout=log, stderr=subprocess.STDOUT,
                start_new_session=(os.name == "posix"),
            )
        JOBS[jid] = proc

    def enforce_timeout():
        try:
            proc.wait(timeout=MAX_JOB_SECONDS)
        except subprocess.TimeoutExpired:
            if os.name == "posix":
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
            else:
                proc.terminate()
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    proc.kill()

    threading.Thread(target=enforce_timeout, name=f"job-timeout-{jid}", daemon=True).start()


@app.get("/health")
def health():
    return {"status": "ok", "llama_cpp": bool(LLAMA)}


# ---------- dataset & model (upload/list/download/hapus) ----------
@app.post("/datasets")
async def upload_dataset(file: UploadFile = File(...)):
    dest = DATA / "datasets" / safe_name(file.filename or "data.jsonl")
    size = await save_stream(file, dest, MAX_DATASET_UPLOAD_BYTES)
    return {"name": dest.name, "bytes": size}


@app.post("/models")
async def upload_model(file: UploadFile = File(...)):
    dest = out_path(safe_name(file.filename or "model.gguf"))
    size = await save_stream(file, dest, MAX_MODEL_UPLOAD_BYTES)
    return {"name": dest.name, "bytes": size}


@app.get("/models")
def list_models():
    items = []
    for e in sorted((DATA / "models").iterdir()):
        if e.name.endswith(".part"):
            continue
        size = e.stat().st_size if e.is_file() else sum(f.stat().st_size for f in e.rglob("*") if f.is_file())
        items.append({"name": e.name, "dir": e.is_dir(), "bytes": size})
    return items


@app.get("/models/{name:path}")
def get_model(name: str):
    p = model_path(name)
    if not p.is_file():
        raise HTTPException(404, "bukan file / tidak ada")
    return FileResponse(p, filename=p.name)  # mendukung Range -> unduhan bisa dilanjutkan


@app.delete("/models/{name:path}")
def delete_model(name: str):
    p = model_path(name)
    if not p.exists():
        raise HTTPException(404, "tidak ada")
    shutil.rmtree(p) if p.is_dir() else p.unlink()
    return {"ok": True}


# ---------- training ----------
class TrainReq(BaseModel):
    method: str = Field(default="LORA", pattern="^(FULL_FINETUNE|LORA|QLORA|DPO)$")
    base_model: str = Field(default="Qwen/Qwen2.5-0.5B-Instruct", min_length=1, max_length=256)
    dataset: str = Field(min_length=1, max_length=255)
    learning_rate: float = Field(default=2e-4, gt=0, le=1)
    epochs: int = Field(default=1, ge=1, le=100)
    batch_size: int = Field(default=2, ge=1, le=256)
    lora_rank: int = Field(default=8, ge=1, le=1024)
    lora_alpha: int = Field(default=16, ge=1, le=4096)
    max_seq_len: int = Field(default=1024, ge=8, le=131072)
    val_dataset: str = Field(default="", max_length=255)


@app.post("/train")
def start_train(r: TrainReq):
    ds = DATA / "datasets" / safe_name(r.dataset)
    if not ds.exists():
        raise HTTPException(404, "dataset belum diunggah")
    cmd_val = []
    if r.val_dataset:
        vds = DATA / "datasets" / safe_name(r.val_dataset)
        if not vds.exists():
            raise HTTPException(404, "dataset validasi belum diunggah")
        cmd_val = ["--val", vds]
    jid = uuid.uuid4().hex[:8]
    (DATA / "jobs" / jid).mkdir()
    (DATA / "jobs" / jid / "request.json").write_text(r.model_dump_json())
    try:
        spawn([sys.executable, HERE / "train_lora.py", "--method", r.method, "--base_model", resolve(r.base_model),
               "--dataset", ds, "--out", DATA / "jobs" / jid / "out", "--lr", r.learning_rate, "--epochs", r.epochs,
               "--batch", r.batch_size, "--rank", r.lora_rank, "--alpha", r.lora_alpha, "--max_len", r.max_seq_len, *cmd_val], jid)
    except Exception:
        shutil.rmtree(DATA / "jobs" / jid, ignore_errors=True)
        raise
    return {"job_id": jid}


# ---------- operasi model ----------
class OpReq(BaseModel):
    op: str  # DOWNLOAD_HF | CONVERT_TO_GGUF | QUANTIZE | MERGE_LORA | MERGE_MODELS | INSPECT | SET_GGUF_META
    params: dict = {}


sys.path.insert(0, str(HERE))
from convert_check import inspect_source


@app.post("/ops")
def run_op(r: OpReq):
    p, op, W, py = r.params, r.op, HERE / "ops_worker.py", sys.executable
    if op == "DOWNLOAD_HF":
        need(p, "source")
        cmd = [py, W, "download", "--repo", hf_repo(p["source"]), "--out", out_path(p.get("output") or p["source"].replace("/", "__")), "--token", p.get("token", "")]
    elif op == "CONVERT_TO_GGUF":
        need(p, "source", "output")
        info = inspect_source(resolve(p["source"]))
        if not info["ok"]:
            raise HTTPException(400, info["message"])
        cmd = [py, need_llama() / "convert_hf_to_gguf.py", resolve(p["source"]), "--outfile", out_path(p["output"]), "--outtype", p.get("outtype", "f16")]
    elif op == "QUANTIZE":
        need(p, "source", "output", "quant")
        exe = os.environ.get("LLAMA_QUANTIZE") or str(need_llama() / "build" / "bin" / "llama-quantize")
        cmd = [exe, resolve(p["source"]), out_path(p["output"]), p["quant"]]
    elif op == "MERGE_LORA":
        need(p, "source", "adapter", "output")
        cmd = [py, W, "merge_lora", "--base", resolve(p["source"]), "--adapter", resolve(p["adapter"]), "--out", out_path(p["output"])]
    elif op == "MERGE_MODELS":
        srcs = p.get("sources") or []
        ws = p.get("weights") or [1.0] * len(srcs)
        need(p, "output")
        if len(srcs) < 2 or len(ws) != len(srcs):
            raise HTTPException(400, "minimal 2 model dan jumlah weights harus sama")
        cmd = [py, W, "merge_models", "--models", ",".join(resolve(s) for s in srcs), "--weights", ",".join(str(w) for w in ws), "--out", out_path(p["output"])]
    elif op == "INSPECT":
        need(p, "source")
        cmd = [py, W, "inspect", "--path", resolve(p["source"])]
    elif op == "SET_GGUF_META":
        need(p, "source", "output", "key", "value")
        cmd = [py, W, "set_meta", "--llama", need_llama(), "--src", resolve(p["source"]), "--out", out_path(p["output"]), "--key", p["key"], "--value", p["value"]]
    else:
        raise HTTPException(400, f"op tidak dikenal: {op}")
    jid = uuid.uuid4().hex[:8]
    spawn(cmd, jid)
    return {"job_id": jid}


# ---------- job: progress, batal, hasil ----------
@app.get("/train/{jid}/events")
@app.get("/jobs/{jid}/events")
async def events(jid: str):
    proc, logf = JOBS.get(jid), DATA / "jobs" / jid / "log.txt"
    if proc is None or not logf.exists():
        raise HTTPException(404, "job tidak ditemukan")

    async def gen():
        with open(logf, encoding="utf-8") as f:
            while True:
                line = f.readline()
                if line:
                    line = line.strip()
                    yield f"data: {line if line.startswith('{') else json.dumps({'log': line[-300:]})}\n\n"
                    continue
                if proc.poll() is not None:
                    yield f"data: {json.dumps({'status': 'done' if proc.returncode == 0 else 'error', 'code': proc.returncode})}\n\n"
                    return
                await asyncio.sleep(0.5)

    return StreamingResponse(gen(), media_type="text/event-stream")


@app.post("/train/{jid}/cancel")
@app.post("/jobs/{jid}/cancel")
def cancel(jid: str):
    p = JOBS.get(jid)
    if p and p.poll() is None:
        p.terminate()
    return {"ok": True}


@app.get("/adapters/{jid}")
def adapter_zip(jid: str):
    d = DATA / "jobs" / jid / "out" / "adapter"
    if not d.exists():
        raise HTTPException(404, "adapter belum ada")
    z = shutil.make_archive(str(DATA / "jobs" / jid / "adapter"), "zip", d)
    return FileResponse(z, filename=f"adapter-{jid}.zip")


@app.post("/convert/lora/{jid}")
def convert_lora_to_gguf(jid: str):
    """Adapter LoRA -> GGUF (dimuat llama.cpp di HP)."""
    llama = need_llama()
    jdir = DATA / "jobs" / jid
    req = json.loads((jdir / "request.json").read_text())
    out = jdir / "adapter.gguf"
    res = subprocess.run([sys.executable, str(llama / "convert_lora_to_gguf.py"), "--base-model-id", req["base_model"],
                          "--outfile", str(out), str(jdir / "out" / "adapter")], capture_output=True, text=True)
    if res.returncode != 0:
        raise HTTPException(500, res.stderr[-500:])
    return FileResponse(out, filename=f"adapter-{jid}.gguf")
