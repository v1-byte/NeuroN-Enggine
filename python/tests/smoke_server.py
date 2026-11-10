"""Smoke test server Python (tanpa perlu server berjalan).

Jalankan:  python python/tests/smoke_server.py
Memakai fastapi & pydantic sungguhan jika terpasang. Jika tidak, memakai stub di tests/_stubs
(hanya meniru bentuk API yang dipakai server.py; perilaku HTTP asli TIDAK diuji dengan stub).
Tidak menjalankan proses training/konversi: spawn() diganti pencatat.
Keluar dengan kode 1 bila ada yang gagal.
"""
import ast, builtins, json, os, symtable, sys, tempfile, traceback
from pathlib import Path

sys.dont_write_bytecode = True  # jangan menulis __pycache__ ke repo
HERE = Path(__file__).resolve().parent
PY = HERE.parent

try:
    import fastapi, pydantic  # noqa: F401
    MODE = "REAL (fastapi & pydantic sungguhan)"
except ImportError:
    sys.path.insert(0, str(HERE / "_stubs"))
    MODE = "STUB (fastapi/pydantic tidak terpasang; HTTP asli tidak diuji)"

results = []
def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(("PASS " if ok else "FAIL ") + name + ("" if ok or not detail else f"  -- {detail}"))

print("mode:", MODE)

# ---------- 1) sintaks & nama tak terdefinisi (statis) ----------
ALLOW = {"__file__", "__name__", "__doc__", "__spec__", "__package__", "__builtins__"}
def undefined_names(src: str, label: str):
    top = symtable.symtable(src, label, "exec")
    defined = set()
    def collect(t):
        for s in t.get_symbols():
            if s.is_assigned() or s.is_imported() or s.is_namespace() or s.is_declared_global():
                defined.add(s.get_name())
        for c in t.get_children(): collect(c)
    collect(top)
    problems = set()
    def walk(t):
        for s in t.get_symbols():
            n = s.get_name()
            if s.is_referenced() and (t is top or s.is_global()) and n not in defined | ALLOW and not hasattr(builtins, n):
                problems.add((n, t.get_name(), t.get_lineno()))
        for c in t.get_children(): walk(c)
    walk(top)
    return sorted(problems)

FILES = ["server.py", "convert_check.py", "ops_worker.py", "train_lora.py"]
for f in FILES:
    src = (PY / f).read_text(encoding="utf-8")
    try:
        compile(src, f, "exec")
        check(f"sintaks {f}", True)
    except SyntaxError as e:
        check(f"sintaks {f}", False, f"baris {e.lineno}: {e.msg}")
        continue
    probs = undefined_names(src, f)
    check(f"nama terdefinisi {f}", not probs, "; ".join(f"{n} di {s}:{l}" for n, s, l in probs))

# kontrol negatif: pemeriksa harus menangkap typo yang sengaja dibuat
bad = "def f():\n    return nama_tidak_ada + 1\nprint(dua_tidak_ada)\n"
neg = undefined_names(bad, "kontrol")
check("kontrol negatif: typo tertangkap", {n for n, _, _ in neg} == {"nama_tidak_ada", "dua_tidak_ada"}, str(neg))

# ---------- 2) impor server.py & uji endpoint/helper ----------
tmp = Path(tempfile.mkdtemp(prefix="neuron-smoke-"))
os.environ.update({"NEURON_DATA": str(tmp / "data"), "NEURON_API_KEY": "rahasia", "LLAMA_CPP_DIR": str(tmp / "llama")})
(tmp / "llama").mkdir()
(tmp / "llama" / "convert_hf_to_gguf.py").write_text("# dummy untuk uji\n")
sys.path.insert(0, str(PY))
# server tanpa API key harus menolak berjalan
import importlib.util as _iu
_saved = os.environ.pop("NEURON_API_KEY")
try:
    _sp = _iu.spec_from_file_location("server_nokey", PY / "server.py")
    _m = _iu.module_from_spec(_sp); _sp.loader.exec_module(_m)
    check("server tanpa API key ditolak saat start", False, "tidak melempar")
except RuntimeError:
    check("server tanpa API key ditolak saat start", True)
except Exception:
    check("server tanpa API key ditolak saat start", False, traceback.format_exc().splitlines()[-1])
os.environ["NEURON_API_KEY"] = _saved
try:
    import server as S
    check("impor server.py", True)
except Exception:
    check("impor server.py", False, traceback.format_exc().splitlines()[-1])
    S = None

if S is not None:
    routes = {(m, p) for m, p, _ in S.app.routes}
    expected = {("GET","/health"),("POST","/datasets"),("POST","/models"),("GET","/models"),("GET","/models/{name:path}"),
                ("DELETE","/models/{name:path}"),("POST","/train"),("POST","/ops"),("GET","/train/{jid}/events"),
                ("GET","/jobs/{jid}/events"),("POST","/train/{jid}/cancel"),("POST","/jobs/{jid}/cancel"),
                ("GET","/adapters/{jid}"),("POST","/convert/lora/{jid}")}
    check("route terdaftar lengkap", routes == expected, f"hilang={expected-routes} ekstra={routes-expected}")
    check("health", S.health() == {"status": "ok", "llama_cpp": True})

    check("safe_name buang path traversal", S.safe_name("../../etc/passwd.jsonl") == "passwd.jsonl")
    try:
        S.model_path("../../etc"); check("model_path tolak traversal", False, "tidak melempar")
    except S.HTTPException as e:
        check("model_path tolak traversal", e.status_code == 400)
    check("resolve membiarkan id repo HF", S.resolve("Qwen/Qwen2.5-0.5B-Instruct") == "Qwen/Qwen2.5-0.5B-Instruct")
    (S.DATA / "models").mkdir(parents=True, exist_ok=True)
    (S.DATA / "models" / "m.gguf").write_text("x")
    check("resolve mengembalikan path model server", S.resolve("m.gguf") == str(S.DATA / "models" / "m.gguf"))

    try:
        S.auth(x_api_key="")
        check("auth tolak key kosong", False)
    except S.HTTPException as e:
        check("auth tolak key kosong", e.status_code == 401)
    try:
        S.auth(x_api_key="salah"); check("auth tolak key salah", False)
    except S.HTTPException as e:
        check("auth tolak key salah", e.status_code == 401)
    try:
        S.auth(x_api_key="rahasia"); check("auth terima key benar", True)
    except Exception as e:
        check("auth terima key benar", False, repr(e))

    # source di luar folder models harus ditolak
    (tmp / "secret").mkdir(exist_ok=True); os.chdir(tmp)  # folder lokal relatif terhadap cwd
    for bad in ("/etc/passwd", "/", "../../etc", "..", ".", "secret", "/home/user/model"):
        try:
            S.resolve(bad); check(f"resolve tolak source di luar models: {bad}", False, "tidak melempar")
        except S.HTTPException as e:
            check(f"resolve tolak source di luar models: {bad}", e.status_code == 400)

    spawned = []
    S.spawn = lambda cmd, jid: spawned.append([str(c) for c in cmd])  # pencatat, tidak menjalankan proses
    def mkdir_model(name, files, config=None):
        d = S.DATA / "models" / name
        d.mkdir(parents=True, exist_ok=True)
        for f in files: (d / f).write_text("x")
        if config is not None: (d / "config.json").write_text(json.dumps(config))
    mkdir_model("awq-src", ["model.safetensors"], {"quantization_config": {"quant_method": "awq"}})
    mkdir_model("fp16-src", ["model.safetensors"], {"torch_dtype": "float16"})
    mkdir_model("onnx-src", ["model.onnx"])

    def op_error(params, op="CONVERT_TO_GGUF"):
        try:
            S.run_op(S.OpReq(op=op, params=params)); return None
        except S.HTTPException as e:
            return e
    spawned.clear()
    for _op, _extra in (("INSPECT", {}), ("CONVERT_TO_GGUF", {"output": "x.gguf"}), ("DOWNLOAD_HF", {})):
        e = op_error({"source": "/etc/passwd", **_extra}, op=_op)
        check(f"op {_op} source path absolut ditolak 400 sebelum spawn", e is not None and e.status_code == 400 and not spawned)
    spawned.clear()
    e = op_error({"source": "awq-src", "output": "x.gguf"})
    check("convert AWQ ditolak 400 sebelum spawn", e is not None and e.status_code == 400 and not spawned)
    e = op_error({"source": "onnx-src", "output": "x.gguf"})
    check("convert ONNX ditolak 400", e is not None and e.status_code == 400 and not spawned)
    e = op_error({"source": "fp16-src", "output": "fp16.gguf", "outtype": "q8_0"})
    check("convert safetensors FP16 lolos", e is None and len(spawned) == 1, str(getattr(e, "detail", "")))
    if spawned:
        cmd = spawned[0]
        check("cmd convert memakai convert_hf_to_gguf & outtype", any("convert_hf_to_gguf.py" in c for c in cmd) and "q8_0" in cmd, " ".join(cmd))
    spawned.clear()
    e = op_error({"source": "fp16-src"})
    check("parameter wajib 'output' dicek", e is not None and e.status_code == 400)
    e = op_error({}, op="NOPE")
    check("op tidak dikenal 400", e is not None and e.status_code == 400)

    (S.DATA / "datasets").mkdir(parents=True, exist_ok=True)
    def train(**kw):
        base = dict(method="LORA", base_model="Qwen/x", dataset="ds_train.jsonl", learning_rate=2e-4, epochs=1, batch_size=2,
                    lora_rank=8, lora_alpha=16, max_seq_len=1024, val_dataset="")
        base.update(kw)
        try:
            return S.start_train(S.TrainReq(**base)), None
        except S.HTTPException as e:
            return None, e
    spawned.clear()
    _, e = train()
    check("train: dataset belum ada -> 404", e is not None and e.status_code == 404)
    (S.DATA / "datasets" / "ds_train.jsonl").write_text("{}\n")
    _, e = train(val_dataset="ds_val.jsonl")
    check("train: val belum ada -> 404", e is not None and e.status_code == 404)
    (S.DATA / "datasets" / "ds_val.jsonl").write_text("{}\n")
    res, e = train(val_dataset="ds_val.jsonl")
    cmd = spawned[0] if spawned else []
    check("train: dengan val -> cmd punya --val", e is None and "--val" in cmd and cmd[cmd.index("--val") + 1].endswith("ds_val.jsonl"), str(getattr(e, "detail", "")))
    spawned.clear()
    res, e = train(val_dataset="")
    cmd = spawned[0] if spawned else []
    check("train: tanpa val -> cmd tanpa --val", e is None and "--val" not in cmd)
    check("train: request.json ditulis", res is not None and (S.DATA / "jobs" / res["job_id"] / "request.json").exists())

# ---------- 3) train_lora.py: fungsi murni (tanpa torch) ----------
import importlib.util
spec = importlib.util.spec_from_file_location("train_lora", PY / "train_lora.py")
TL = importlib.util.module_from_spec(spec); spec.loader.exec_module(TL)
jl = tmp / "a.jsonl"; jl.write_text('{"instruction":"Halo","output":"Hai"}\n\n{"messages":[{"role":"user","content":"x"},{"role":"assistant","content":"y"}]}\n', encoding="utf-8")
rows = TL.load_rows(str(jl))
check("load_rows jsonl (lewati baris kosong)", len(rows) == 2)
cs = tmp / "b.csv"; cs.write_text("instruction,output\nHalo,Hai\n", encoding="utf-8")
check("load_rows csv", TL.load_rows(str(cs)) == [{"instruction": "Halo", "output": "Hai"}])
js = tmp / "c.json"; js.write_text('[{"prompt":"p","output":"o"}]', encoding="utf-8")
check("load_rows json", TL.load_rows(str(js)) == [{"prompt": "p", "output": "o"}])
msgs = TL.to_messages({"instruction": "Halo", "input": "konteks", "output": "Hai"})
check("to_messages instruction+input", msgs[0]["content"] == "Halo\n\nkonteks" and msgs[1] == {"role": "assistant", "content": "Hai"})
check("to_messages messages dipertahankan", TL.to_messages({"messages": [{"role": "user", "content": "q"}]}) == [{"role": "user", "content": "q"}])
src = (PY / "train_lora.py").read_text(encoding="utf-8")
check("train_lora punya argumen --val", any(isinstance(n, ast.Call) and getattr(n.func, "attr", "") == "add_argument" and n.args and getattr(n.args[0], "value", "") == "--val" for n in ast.walk(ast.parse(src))))

# ---------- ringkasan ----------
failed = [n for n, ok in results if not ok]
print(f"\nRINGKASAN ({MODE.split(' ')[0]}): {len(results) - len(failed)}/{len(results)} lulus")
if failed:
    print("GAGAL:"); [print("  -", n) for n in failed]
sys.exit(1 if failed else 0)
