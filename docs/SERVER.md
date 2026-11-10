# Server lokal (OpenAI-compatible) di Android

Aplikasi dapat menjalankan engine aktif sebagai API pada IPv4 interface jaringan yang dipilih. Server memakai HTTP tanpa TLS; bearer key akan terlihat pada jaringan yang dapat mengamati trafik. Gunakan hanya pada jaringan tepercaya dan jangan meneruskan port ini ke internet.

## Mulai atau hentikan server

1. Buka **Lainnya → Tools → Server lokal**.
2. Atur port (default `8080`). Buat API key dengan tombol **Buat key acak 256-bit**. Key minimal 32 karakter dan disimpan terenkripsi melalui `SecretStore` setelah disimpan. Gunakan ikon mata untuk menampilkan key sementara lalu salin ke klien; sembunyikan kembali setelah selesai.
   Key lama yang kurang dari 32 karakter tidak lagi diterima; buat key baru sebelum memulai server setelah update.
3. Tekan **Simpan & mulai**. Dialog akan meminta konfirmasi bahwa server memakai HTTP tanpa enkripsi; batalkan jika jaringan tidak tepercaya.
4. Aplikasi menampilkan URL server dan tombol **Hentikan**. Listener bind ke satu alamat IPv4 non-loopback aktif yang dipilih `NetInfo`; bila tidak tersedia, ia hanya bind ke `127.0.0.1`. Alamat tersebut tidak selalu merupakan Wi-Fi yang diinginkan pada perangkat dengan beberapa interface, jadi periksa URL yang ditampilkan.
5. Setelah selesai, tekan **Hentikan** atau tombol Stop pada notifikasi foreground service.

Server harus dimulai secara eksplisit dari UI. Android release memblokir koneksi HTTP **keluar** ke endpoint API; pengecualian cleartext hanya ada pada build debug. Kebijakan outbound tersebut terpisah dari server **masuk** ini, yang tetap HTTP dan hanya layak untuk jaringan privat tepercaya.

## Endpoint

| Method | Path | Auth | Keterangan |
|---|---|---|---|
| GET | `/health` | Tidak | Cek hidup |
| GET | `/v1/models` | Bearer | Daftar model (`local`) |
| POST | `/v1/chat/completions` | Bearer | Chat non-stream atau SSE (`stream: true`) |
| POST | `/v1/embeddings` | Bearer | `input` string atau array string |

Semua endpoint selain `/health` mewajibkan `Authorization: Bearer <API_KEY>`. `content` dapat berupa string atau array bagian teks. Parameter yang dihormati mencakup `temperature`, `top_p`, `max_tokens`, dan `stop`; parameter lain berasal dari `chat/params.json`.

## Tes dari komputer pada jaringan yang sama

Ganti URL dan `API_KEY` dengan nilai yang tampil/diatur di aplikasi. Jangan menaruh key nyata ke repo, issue, atau log yang dibagikan.

```bash
BASE_URL=http://192.168.x.x:8080
API_KEY='ISI_KEY_ANDA'

# Health publik
curl "$BASE_URL/health"

# Model (memerlukan Bearer key)
curl "$BASE_URL/v1/models" \
  -H "Authorization: Bearer $API_KEY"

# Chat non-stream
curl "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Halo, siapa kamu?"}],"max_tokens":128}'

# Chat stream (-N agar output tidak di-buffer curl)
curl -N "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hitung 1 sampai 5"}],"stream":true}'

# Embeddings (perlu engine/model yang mendukung embedding)
curl "$BASE_URL/v1/embeddings" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"input":"contoh teks"}'
```

Contoh Python SDK:

```python
from openai import OpenAI
client = OpenAI(base_url="http://192.168.x.x:8080/v1", api_key="ISI_KEY_ANDA")
response = client.chat.completions.create(
    model="local", messages=[{"role": "user", "content": "Halo"}]
)
print(response.choices[0].message.content)
```

`401` biasanya berarti key tidak cocok. `503` menandakan model belum siap; periksa model yang dipilih dan log Android.

## Batasan dan keamanan

- Server memakai HTTP tanpa TLS. Bearer key, prompt, dan jawaban tidak dienkripsi pada jaringan. Key acak 256-bit mengurangi risiko tebakan, tetapi **tidak** mencegah penyadapan.
- Jangan gunakan pada Wi-Fi publik, jaringan tamu, atau jaringan yang tidak Anda kendalikan. Jangan expose/forward port ke internet. Hentikan server setelah selesai.
- Listener membatasi bind ke satu IPv4 aktif; pemilihan interface pertama tidak selalu sama dengan Wi-Fi yang dimaksud. Periksa alamat yang ditampilkan.
- Satu generasi berjalan pada satu waktu; permintaan lain antre melalui `EngineHub.gate`.
- Pemanggilan tool berbasis prompt; respons belum memakai format OpenAI `tool_calls`. Embedding menggunakan engine yang sama, bukan model embedding khusus.
- API HTTP eksternal yang dipakai dalam **APK release** harus HTTPS. Build debug mengizinkan HTTP untuk pengujian lokal saja.
- Uji perangkat nyata tetap diperlukan untuk perilaku jaringan, start/stop service, Android 14+, restart service, dan model yang didukung.
