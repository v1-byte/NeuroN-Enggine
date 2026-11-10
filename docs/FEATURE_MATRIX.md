# Peta Fitur -> File Editor -> Modul

| Fitur | File virtual (tab editor) | Modul | Bisa jalan di HP? |
|---|---|---|---|
| System prompt, temp, top-p/k, min-p, penalties, max tokens, seed, stop, context | chat/params.json | model, engine | Ya |
| Modelfile, chat template, config.json, generation_config.json | model/* | project, engine | Ya. Modelfile (SYSTEM/PARAMETER) dan generation_config dibaca `ModelDefaults` untuk engine lokal dan API; template dipakai engine lokal; config.json hanya untuk cek konsistensi Copilot |
| Quantization | model/quantization.json | engine | Pilih varian GGUF; re-quantize butuh tool llama-quantize (bisa dibuat via NDK, berat) |
| Format GGUF | - | engine (llama.cpp) | Ya |
| Format ONNX | - | engine (onnxruntime-genai) | Ya, terbatas |
| Safetensors / AWQ / GPTQ | - | server konversi | Tidak langsung: konversi ke GGUF di PC |
| Tokenizer vocab & special tokens | tokenizer/* | engine | **vocab.json hanya data project, TIDAK tersambung ke tokenizer GGUF** (engine memakai tokenizer bawaan model). Pengecualian: `special.eos` ikut menjadi stop sequence di kedua engine. Dipakai Copilot untuk cek konsistensi dengan config.json. Ubah vocab = model rusak kecuali dilatih ulang |
| RAG, vector DB, embedding, knowledge file | knowledge/* | rag | Ya |
| Fine-tune, LoRA/QLoRA, DPO/RLHF, dataset, LR, epoch, batch, rank, alpha | training/* | train | LoRA kecil: ya. QLoRA/DPO/RLHF/full: via server remote |
| GPU layers, threads, batch, KV cache, flash attn, RoPE, logit bias | hardware/engine.json | engine | Ya (GPU layers butuh build Vulkan/OpenCL; awal: CPU) |
| Tools/function calling, guardrails | features/* | engine, server | Ya |
| Vision, TTS, STT | features/* | engine, UI (`flutter_app/`) | Ya (model vision butuh mmproj + RAM besar) |
| Server lokal | server/server.json | server | Ya |
| Copilot | copilot/copilot.json | copilot | Ya (lokal atau API) |
