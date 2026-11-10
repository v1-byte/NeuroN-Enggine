# Vision, TTS, dan STT (langkah 22)

> **Catatan migrasi (2026-11-09):** layar dan tombol di dokumen ini berasal dari UI Compose lama, yang sudah dihapus dari repo. UI Flutter (`flutter_app/`) belum memiliki bagian ini; logika di modul di bawahnya tidak berubah. Lihat [MIGRASI_FLUTTER.md](MIGRASI_FLUTTER.md).


Ketiga fitur diatur lewat `features/features.json`:
- `visionEnabled` → tombol 📷 (lampiran gambar)
- `sttEnabled` → tombol 🎤 (input suara)
- `ttsEnabled` → balasan dibacakan otomatis, dan tombol 🔊 di setiap balasan AI
- `voiceLanguage` → bahasa untuk TTS dan STT, mis. `"id-ID"` atau `"en-US"`. Default `"id"`.

`mmprojPath` **tidak dipakai**. Lihat bagian Batasan.

## 1. Vision (hanya mode API)
- Gambar dipilih lewat picker, diperkecil ke sisi terpanjang 1024 px, dikompres JPEG (kualitas 85), lalu dikirim sebagai data URL.
- Format request mengikuti OpenAI: `content` berupa array berisi `{"type":"text"}` dan `{"type":"image_url"}`.
- Gambar **hanya ikut pada giliran itu**. Riwayat lama tidak dikirim ulang, supaya payload dan context window tidak membengkak.
- Mode LOCAL menolak lampiran gambar dengan pesan jelas. Vision lokal (llama.cpp mtmd / mmproj) belum diimplementasikan.

Untuk mencoba: di `engine/api.json` pilih mode API dengan server yang menerima `image_url` dan memakai model vision
(mis. model llava atau Qwen-VL yang di-serve dengan API OpenAI-compatible). Aktifkan `visionEnabled` di `features.json`.

## 2. TTS (Android)
- Memakai `TextToSpeech` bawaan Android. Engine dan bahasa suara harus sudah terpasang di perangkat.
- Jika bahasa tidak tersedia, app memakai bahasa Inggris (`en-US`).
- Balasan yang belum siap dibacakan (engine TTS belum selesai inisialisasi) akan dibacakan begitu siap.
- ⏹ menghentikan pembacaan.

## 3. STT (Android)
- Memakai `RecognizerIntent.ACTION_RECOGNIZE_SPEECH`. Mikrofon dan izin ditangani oleh aplikasi pengenal suara sistem, jadi app tidak meminta `RECORD_AUDIO` sendiri.
- Hasil dimasukkan ke kolom input. Kamu tetap menekan Kirim.
- Pengenal suara offline harus diunduh di perangkat, jika tidak, pengenal akan memerlukan internet.

## 4. Batasan
- **Vision lokal belum ada.** `mmprojPath` belum dipakai. Itu memerlukan dukungan mtmd di `neuron_llama.cpp`, yang belum diverifikasi.
- **Rotasi EXIF gambar belum diterapkan.** Foto dari kamera bisa tampil miring.
- **Vision bergantung pada server.** Tidak semua server OpenAI-compatible menerima `image_url`, dan tidak semua model adalah model vision.
- **Biaya token gambar** di API bisa besar. Pengecilan ke 1024 px sudah mengurangi, tetapi belum tentu cukup untuk setiap server.
- **Izin RECORD_AUDIO** masih tercantum di manifest, padahal jalur STT sekarang tidak memerlukannya. Bisa dihapus bila tidak dipakai di tempat lain.
- **Belum dikompilasi dan belum diuji** di perangkat.
