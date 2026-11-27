# Privasi per model (`privacy.json`)

Fitur ini membaca aturan privasi dari repo Hugging Face model (bawaan `bytecode66/Froged_N1`), membiarkan
pengguna meninjau dan mengedit, lalu menyimpannya **per model** dan (opsional) menggabungkannya ke guardrail.

## Alur di aplikasi

Lainnya → Fitur → **Edit privasi model**:

1. Pilih model lokal yang terpasang (terunduh, terimpor, atau aktif).
2. Kartu info menampilkan berkas yang diedit (`<model>.gguf.privacy.json`, di samping model), status model, dan repo asal.
3. **Ambil dari <repo>** mengunduh hanya `privacy.json` dari repo asal. Isinya belum disimpan; pengguna meninjau dan mengedit.
4. **Simpan saja** menulis berkas milik model itu. **Simpan & pakai** juga menggabungkan kata/regex ke guardrail, hanya untuk model yang sedang aktif. Gabungan tanpa duplikat; daftar lama tidak dihapus.

Berkas privasi ikut terhapus saat model dihapus. Kode: `model/PrivacyPolicy.kt`, `ProjectBridge.kt` (`privacy*`), `flutter_app/lib/privacy_dialog.dart`.

## Skema yang didokumentasikan

```json
{
  "version": 1,
  "blocked_terms": ["kata terlarang"],
  "regex": ["\\d{16}"]
}
```

- `blocked_terms`: daftar string, menjadi kata terlarang guardrail (tidak peka huruf besar/kecil).
- `regex`: daftar pola regex (sintaks Kotlin/Java). Pola yang tidak valid dilewati dan dilaporkan sebagai peringatan.
- Kunci lain boleh ada; kunci berisi `description`, `comment`, `example`, `note`, `metadata`, `schema`, atau `changelog` selalu diabaikan.

## Status skema: belum dikunci

Skema `privacy.json` milik pemilik model **belum diverifikasi**. Berkas aslinya di Hugging Face tidak diperiksa saat
dokumen ini ditulis (tanpa akses jaringan), jadi parser (`PrivacyPolicy.parse`) menebak dari NAMA KUNCI:

| Dikenali sebagai | Bila nama kunci (di dalam array string) mengandung |
|---|---|
| regex | `regex`, `pattern`, `pola` |
| kata terlarang | `block`, `deny`, `forbid`, `terlarang`, `blokir`, `term`, `word`, `kata`, `istilah`, `keyword`, `sensitive`, `redact`, `phrase` |
| kata terlarang (objek di dalam blok aturan) | kunci `term`, `word`, `kata`, `istilah`, `phrase`, `keyword`, `value`, `text` |

Konsekuensi yang perlu diketahui:

- Hasil **selalu ditampilkan** ke pengguna sebelum dipakai, sehingga tangkapan yang salah bisa dikoreksi di editor.
- Kunci yang kebetulan mengandung kata di atas (mis. `password_policy`) bisa tertangkap sebagai kata terlarang.
- Array tanpa nama kunci di akar dokumen tidak ditebak.
- Satu entri maksimal 500 karakter, 5000 entri, berkas maksimal 2 MB.
- Bila tidak ada yang dikenali, pengguna diberi peringatan, bukan galat.

## Cara mengunci skema (langkah berikutnya)

1. Unduh `privacy.json` asli dari repo model dan simpan sebagai fixture, mis. `engine/src/test/resources/froged_n1_privacy.json`.
2. Tambahkan tes di `PrivacyPolicyTest` yang menegaskan daftar kata dan regex yang diharapkan dari fixture itu.
3. Bila skema ternyata tetap, ganti heuristik nama kunci dengan pembacaan eksplisit dan pertahankan heuristik hanya sebagai cadangan.

## Pengujian

- Kotlin: `engine/src/test/java/com/neuron/engine/PrivacyPolicyTest.kt` (parser, kunci dokumentasi, regex rusak, input kosong/terlalu besar).
- Flutter: `flutter_app/test/privacy_dialog_test.dart` (dialog dengan channel palsu: pilih model, ambil, simpan, tombol pakai, galat).
- Kedua tes **belum dijalankan** (tidak ada Kotlin/Flutter di lingkungan penulisan). Jalankan lewat CI atau `./gradlew :engine:testDebugUnitTest` dan `flutter test`.
