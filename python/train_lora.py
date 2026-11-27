"""Pelatihan SFT / LoRA / QLoRA / DPO. Dijalankan sebagai subprocess oleh server.py.
Setiap baris stdout berformat JSON: {"step":..,"total":..,"loss":..} | {"status":"saved"|"error",..}

Format dataset (jsonl / json / csv):
  SFT : {"instruction","input","output"}  atau  {"messages":[{"role","content"},...]}
  DPO : {"prompt","chosen","rejected"}
"""
import argparse, csv, json, sys
from pathlib import Path


def emit(**kw):
    print(json.dumps(kw, ensure_ascii=False), flush=True)


def load_rows(path):
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    if p.suffix == ".jsonl":
        return [json.loads(l) for l in text.splitlines() if l.strip()]
    if p.suffix == ".json":
        return json.loads(text)
    if p.suffix == ".csv":
        return list(csv.DictReader(text.splitlines()))
    raise ValueError(f"Format dataset tidak didukung: {p.suffix}")


def to_messages(r):
    if "messages" in r:
        return r["messages"]
    ins = r.get("instruction") or r.get("prompt", "")
    inp = r.get("input", "")
    out = r.get("output") or r.get("response", "")
    return [{"role": "user", "content": ins + (("\n\n" + inp) if inp else "")},
            {"role": "assistant", "content": out}]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--method", default="LORA")  # FULL_FINETUNE | LORA | QLORA | DPO
    ap.add_argument("--base_model", required=True)
    ap.add_argument("--dataset", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--lr", type=float, default=2e-4)
    ap.add_argument("--epochs", type=int, default=1)
    ap.add_argument("--batch", type=int, default=2)
    ap.add_argument("--rank", type=int, default=8)
    ap.add_argument("--alpha", type=int, default=16)
    ap.add_argument("--max_len", type=int, default=1024)
    ap.add_argument("--val", default="")  # opsional: dataset validasi
    a = ap.parse_args()

    if a.method == "RLHF":
        raise NotImplementedError("RLHF/PPO belum didukung. Pakai method DPO.")

    import torch
    from datasets import Dataset
    from peft import LoraConfig, prepare_model_for_kbit_training
    from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig, TrainerCallback
    from trl import DPOConfig, DPOTrainer, SFTConfig, SFTTrainer

    cuda = torch.cuda.is_available()
    bf16 = cuda and torch.cuda.is_bf16_supported()
    tok = AutoTokenizer.from_pretrained(a.base_model)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token

    qcfg = None
    if a.method == "QLORA":
        if not cuda:
            raise RuntimeError("QLoRA butuh GPU CUDA. Pakai LORA di CPU (model kecil).")
        qcfg = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                                  bnb_4bit_compute_dtype=torch.bfloat16 if bf16 else torch.float16)
    model = AutoModelForCausalLM.from_pretrained(
        a.base_model, quantization_config=qcfg,
        torch_dtype=(torch.bfloat16 if bf16 else torch.float16) if cuda else torch.float32)
    if qcfg:
        model = prepare_model_for_kbit_training(model)

    peft_cfg = None if a.method == "FULL_FINETUNE" else LoraConfig(
        r=a.rank, lora_alpha=a.alpha, lora_dropout=0.05, target_modules="all-linear", task_type="CAUSAL_LM")

    rows = load_rows(a.dataset)
    val_rows = load_rows(a.val) if a.val else None
    common = dict(output_dir=a.out, num_train_epochs=a.epochs, per_device_train_batch_size=a.batch,
                  learning_rate=a.lr, logging_steps=1, save_strategy="no", report_to="none", bf16=bf16, fp16=cuda and not bf16,
                  eval_strategy="epoch" if val_rows else "no")

    class Prog(TrainerCallback):
        def on_log(self, args, state, control, logs=None, **kw):
            if logs and "loss" in logs:
                emit(step=state.global_step, total=state.max_steps, loss=float(logs["loss"]))

        def on_evaluate(self, args, state, control, metrics=None, **kw):
            if metrics and "eval_loss" in metrics:
                emit(step=state.global_step, total=state.max_steps, eval_loss=float(metrics["eval_loss"]),
                     log=f"eval_loss={metrics['eval_loss']:.4f}")

    def dpo_ds(rs):
        return Dataset.from_list([{"prompt": r["prompt"], "chosen": r["chosen"], "rejected": r["rejected"]} for r in rs])

    def sft_ds(rs):
        return Dataset.from_list([{"text": tok.apply_chat_template(to_messages(r), tokenize=False)} for r in rs])

    if a.method == "DPO":
        trainer = DPOTrainer(model=model, args=DPOConfig(max_length=a.max_len, beta=0.1, **common),
                             train_dataset=dpo_ds(rows), eval_dataset=dpo_ds(val_rows) if val_rows else None,
                             processing_class=tok, peft_config=peft_cfg, callbacks=[Prog()])
    else:
        trainer = SFTTrainer(model=model, args=SFTConfig(dataset_text_field="text", max_seq_length=a.max_len, **common),
                             train_dataset=sft_ds(rows), eval_dataset=sft_ds(val_rows) if val_rows else None,
                             processing_class=tok, peft_config=peft_cfg, callbacks=[Prog()])

    trainer.train()
    out = Path(a.out) / "adapter"
    trainer.model.save_pretrained(out)
    tok.save_pretrained(out)
    emit(status="saved", path=str(out))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa
        emit(status="error", message=str(e))
        sys.exit(1)
