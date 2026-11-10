# Server lokal (OpenAI-compatible) di HP

> **Catatan migrasi (2026-11-09):** layar dan tombol di dokumen ini berasal dari UI Compose lama, yang sudah dihapus dari repo. UI Flutter (`flutter_app/`) belum memiliki bagian ini; logika di modul di bawahnya tidak berubah. Lihat [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).


Menjalankan model yang sedang dimuat sebagai API HTTP di jaringan Wi-Fi yang sama. Laptop atau aplikasi lain
bisa memakainya seperti server OpenAI.

## 1. Menjalankan
1. Di app: tombol **🖧 Server**.
2. Atur port (default 8080) dan API key (WAJIB, minimal 8 karakter; tombol "Buat API key acak" tersedia, server tidak mau jalan tanpa kunci). Lalu **Mulai server**.
3. Alamat `http://IP_HP:PORT` tampil di layar dan di notifikasi. Notifikasi punya tombol **Stop**.
4. Server berjalan sebagai foreground service dengan wake lock dan Wi-Fi lock, jadi tetap hidup saat layar mati.
   Model dimuat otomatis dari project `default` pada permintaan pertama (memakai engine yang sama dengan chat uji).

## 2. Endpoint
| Method | Path | Keterangan |
|---|---|---|
| GET | `/health` | Cek hidup, tanpa API key |
| GET | `/v1/models` | Daftar model (id: `local`) |
| POST | `/v1/chat/completions` | Non-stream, atau `"stream": true` (SSE, diakhiri `data: [DONE]`) |
| POST | `/v1/embeddings` | `input` string atau daftar string |

Parameter yang dihormati: `temperature`, `top_p`, `max_tokens`, `stop`. Lainnya diambil dari `chat/params.json`.
`content` boleh string atau daftar bagian `[{"type":"text","text":"..."}]`.

Jika API key diisi, semua route selain `/health` wajib membawa `Authorization: Bearer <kunci>`.

## 3. Tes dari laptop (langkah 13)
Ganti `192.168.x.x:8080` dengan alamat dari layar Server.

```bash
# 1. Hidup?
curl http://192.168.x.x:8080/health

# 2. Model
curl http://192.168.x.x:8080/v1/models

# 3. Chat tanpa stream
curl http://192.168.x.x:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Halo, siapa kamu?"}],"max_tokens":128}'

# 4. Chat dengan stream (-N agar output tidak di-buffer curl)
curl -N http://192.168.x.x:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hitung 1 sampai 5"}],"stream":true}'

# 5. Dengan API key (jika diisi di layar Server)
curl http://192.168.x.x:8080/v1/models -H "Authorization: Bearer KUNCI_ANDA"

# 6. Embeddings (perlu model yang mendukung embedding)
curl http://192.168.x.x:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input":"contoh teks"}'
```

Contoh dengan SDK Python resmi (`pip install openai`):
```python
from openai import OpenAI
client = OpenAI(base_url="http://192.168.x.x:8080/v1", api_key="KUNCI_ANDA_ATAU_BEBAS")
r = client.chat.completions.create(model="local", messages=[{"role": "user", "content": "halo"}])
print(r.choices[0].message.content)
```

Respons harapan untuk tes 3: JSON dengan `choices[0].message.content` berisi jawaban. Respons 401 berarti API key
salah; 503 berarti model belum bisa dimuat (cek tab model/quantization.json atau log `NeuroN-llama` di logcat).

## 4. Batasan yang perlu diketahui
- **Satu generate pada satu waktu.** Permintaan lain menunggu tanpa batas waktu di `EngineHub.gate`. Chat uji di HP juga memakai gate ini, jadi keduanya antre bergiliran.
- **Field `usage` tidak dikirim.** Engine tidak mengembalikan jumlah token; klien yang butuh hitungan token perlu memperkirakan sendiri.
- **Tool calling** berbasis prompt (lihat `docs/TOOLS_GUARDRAILS.md`). Hasil pemanggilan tool muncul sebagai teks di `content`, bukan `tool_calls`.
- **Guardrail berlaku** untuk permintaan API, sama seperti chat uji.
- **Embeddings** memakai engine chat yang sama, bukan model embedding terpisah.
- **QR belum ada.** Alamat ditampilkan sebagai teks saja.
- **Alamat IP** diambil dari antarmuka jaringan pertama yang aktif. Jika HP punya beberapa jaringan (mis. hotspot dan Wi-Fi), pilih yang sesuai secara manual.
- **Tidak ada HTTPS.** Trafik dalam jaringan lokal tidak terenkripsi; API key ikut terkirim sebagai teks biasa. Jangan pakai di jaringan publik.
- **Belum dikompilasi/diuji di perangkat.**
