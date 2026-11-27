# Changelog

Format mengikuti [Keep a Changelog](https://keepachangelog.com/). Versi di `flutter_app/pubspec.yaml` dan
`flutter_app/lib/app_info.dart` harus sama dengan entri teratas; CI memeriksanya.

## [Unreleased]

### Ditambahkan
- Edit model, tab **Tokenizer** (`tokenizer_tab.dart`, `tokenizer_logic.dart`): ringkasan key `tokenizer.*`, pemeriksaan kewajaran (ID di luar vocab, EOS hilang, BPE tanpa merges), teks token khusus, dan penjelajah daftar token per halaman (hanya baca). Pencarian hanya mencakup halaman yang sedang dibuka.
- Editor kode: **lipat blok** JSON (selama ada blok terlipat tampilan hanya-baca; teks tidak pernah diubah) dan **autocomplete** (kunci `ChatParams`, kata kunci Modelfile/Jinja, kata dari isi berkas). Logika di `editor_assist.dart`.
- **Tab berkas bertahan** setelah aplikasi ditutup (`tab_session.dart`, SharedPreferences). `engine/api.json` tidak pernah dipulihkan otomatis.
- Edit model, tab **Parameter model**: parameter generate per model (temperature, top-p, top-k, min-p, repeat penalty, max tokens, seed, panjang konteks) plus **uji cepat** pada model aktif. Kotlin: `ModelParamOverride`, `ModelDefaults.perModel`/`base`, `ModelParamsBridge`; disimpan di SharedPreferences dengan kunci nama berkas GGUF (ganti nama model memutus penimpasnya).
- Tes baru (BELUM dijalankan): `tokenizer_logic_test`, `editor_assist_test`, `tab_session_test`, `model_params_logic_test`, tambahan di `model_editor_page_test`, dan `ModelParamOverrideTest` (JUnit).

- `LICENSE` (Apache License 2.0, teks resmi tanpa perubahan) dan `NOTICE` (hak cipta Frostbyte Technologies, 2026).
- `docs/PRIVACY.md`: alur, skema yang didokumentasikan, status skema (belum dikunci), dan cara mengunci dengan fixture asli.
- Tes: `PrivacyPolicyTest` (+7 kasus: skema terdokumentasi, kunci dokumentasi, nilai non-string, skema tak dikenal, array akar, entri terlalu panjang, input kosong/besar) dan `flutter_app/test/privacy_dialog_test.dart`. Belum dijalankan.

### Diubah
- `scripts/setup_native.sh` ditulis ulang: idempoten, memakai `.gitmodules`, menambah submodule bila belum terdaftar, meng-clone langsung bila bukan repo git (zip tanpa `.git`), opsi `--tag` dan `--vulkan`.
- `engine/build.gradle.kts`: build `-PwithNative` gagal lebih awal dengan pesan jelas bila source llama.cpp belum ada.
- `PrivacyPolicy`: kunci dokumentasi (`description`, `comment`, `example`, `note`, `metadata`, `schema`, `changelog`) tidak lagi dibaca sebagai aturan.
- Dokumentasi disinkronkan: README (versi 0.3.9, tabel status fitur, bagian lisensi/batasan), `FEATURE_MATRIX.md`, `STATUS.md`, `NATIVE.md`, `flutter_app/README.md`; `ENGINE_GAPS.md` ditulis ulang karena merujuk modul yang sudah dihapus.

### Diperbaiki
- Rujukan ke berkas yang tidak ada (`docs/SERVER.md`, `app/proguard-rules.pro`) dihapus atau diberi catatan.

## [0.3.9] - 2026-11-26

### Ditambahkan
- **Baca model total** di Editor GGUF: selain metadata, kini terbaca seluruh tabel tensor (nama, bentuk, tipe kuantisasi, ukuran), jumlah parameter, ukuran per tipe kuantisasi, nama kuantisasi dari `general.file_type` (mis. Q4_K_M), dan isi array metadata (daftar token dsb.) per halaman. Pemeriksaan integritas memastikan semua data tensor ada di berkas, sejajar, tidak tumpang tindih, dan jumlah blok cocok dengan header; model terpotong (unduhan belum lengkap, mis. Froged N1 yang dijeda) dilaporkan jelas dan tidak bisa disalin saat simpan. Logika di `engine/GgufMeta.kt` (`GgufReader.readTensors/analyze/readArray`, `GgmlTypes`), bridge `ggufInspect`/`ggufTensors`/`ggufArray`.
- Editor GGUF (Lainnya → Tools): baca dan ubah metadata model lokal langsung di HP tanpa server (nama, `tokenizer.chat_template`, ID token khusus, tambah/hapus key). Hasil disimpan sebagai salinan baru `<nama>-edited-<waktu>.gguf`; bobot disalin utuh dan diverifikasi, model asli tidak diubah. Key yang menentukan arsitektur/bentuk tensor dan array (daftar token) dikunci. Logika di `engine/GgufMeta.kt` (+ `GgufMetaTest`).
- Editor project memberi catatan pada berkas yang tidak mengubah model yang berjalan (`model/config.json`, `tokenizer/vocab.json`, `tokenizer/tokenizer.json`, `model/ops.json`).
- Pencarian Hugging Face kini menampilkan model GGUF lokal yang cocok berdasarkan nama file atau repo sumber; layar Model lokal tetap menyediakan rename, verifikasi, dan hapus dengan konfirmasi.
- Model unduhan dari Model Hub menyimpan repo sumber, revision commit Hugging Face, dan SHA-256 dalam sidecar privat per file.
- Model terhubung kini memeriksa revision HEAD Hugging Face dan menampilkan peringatan bila ada pembaruan. File terpasang tidak ditimpa otomatis; pengguna dapat meninjau repo dan memilih unduhan secara sadar.
- Penghapusan model ikut menghapus metadata sumber dan rename menjaga metadata tetap terpasang.
- Halaman Model lokal menyediakan kuantisasi GGUF melalui server ModelOps HTTPS: pengguna memilih model/format, menyetujui upload, lalu hasil diunduh sebagai file baru dan divalidasi header GGUF-nya.
- Layar **Ubah bobot** (Lainnya → Tools, `weight_ops_page.dart`) menggantikan kartu kuantisasi lama dan memuat tiga operasi server, semuanya menghasilkan model GGUF baru di HP tanpa mengubah model sumber:
  - **Kuantisasi**: tipe sumber dibaca dari `general.file_type`. Sumber yang sudah terkuantisasi baru bisa diproses setelah pengguna menyalakan "Izinkan kuantisasi ulang" (server memakai `llama-quantize --allow-requantize`; kualitas turun).
  - **Tanam adapter LoRA**: model dasar GGUF + adapter GGUF dari layar LoRA menjadi satu model (op server baru `MERGE_LORA_GGUF`, `llama-export-lora`, skala 0-2).
  - **Gabung model**: rata-rata berbobot 2-6 model bobot penuh (id repo HF atau folder di server) -> GGUF F16 -> kuantisasi opsional -> unduh (`runModelPipeline`). Folder HF dan GGUF F16 antara dihapus dari server setelahnya; bila unduhan gagal, hasil akhir tetap di server dan namanya disebut di pesan error.

- Layar **LoRA** (Lainnya → Tools): impor adapter `.gguf`, periksa kecocokan dengan model aktif (arsitektur dari header; nama model dasar sebagai peringatan), pasang/lepas, atur skala 0–2, dan **uji A/B** (prompt yang sama tanpa vs dengan adapter, greedy, tampil berdampingan beserta token/detik). Pergantian adapter berlaku langsung pada model yang sudah dimuat tanpa memuat ulang model (`EngineHub.applyLora`, `LoraCapable.setLora`). Logika pemeriksaan di `engine/LoraAdapter.kt` (+ `LoraAdapterTest`), sisi Android di `LoraBridge.kt`.

### Diperbaiki
- **Unduhan model aman dari berkas setengah jadi**: data ditulis ke `<file>.part` dan baru diberi nama akhir setelah SHA-256 dari Hub cocok (`hf/HfFiles.kt`, + `HfFilesTest`). Unduhan yang dijeda atau gagal tidak lagi muncul sebagai model terpasang. Sisa `.part` dari revision lain yang gagal checksum dibuang dan diulang sekali dari awal. File lama yang terpotong di nama akhir (skema sebelumnya) diganti dengan unduhan baru.
- **Revision terkunci**: `hfStartDownload`/`hfStartModelDownload` menerima `revision`; file dan checksum diambil dari commit yang sama (bukan lagi `resolve/main`), sehingga revision yang dicatat di sidecar sama dengan file yang benar-benar terunduh. Tanpa revision, dipakai HEAD saat unduhan dimulai. Jeda/lanjut mempertahankan revision.
- Editor GGUF lambat dibuka: daftar model sebelumnya menghitung SHA-256 seluruh model (±490 MB untuk Froged N1) setiap kali dibuka, diimpor, atau disimpan. Hash kini di-cache per (path, ukuran, waktu ubah) dan Editor GGUF tidak memintanya (`localModels(hash: false)`).
- Editor GGUF: model awal (`initialPath`) yang sudah tidak ada kini diberi pesan, bukan diam; membuka model lain saat yang sebelumnya masih dibaca tidak lagi menimpa tampilan dengan hasil yang basi.
- Operasi model: pesan gagal kini memuat kode keluar dan enam baris log terakhir server (sebelumnya hanya "[error]"). Server dan klien menunggu bila job sebelumnya belum benar-benar keluar (503) alih-alih gagal. `QUANTIZE`/`MERGE_LORA_GGUF` menolak sumber yang bukan `.gguf` di server dan output yang sama dengan sumber; tipe kuantisasi, `outtype`, skala LoRA, dan bobot merge divalidasi (400) sebelum proses dijalankan.
- Merge model/LoRA berformat folder HF tidak lagi gagal di langkah unduh ("Output harus berakhiran .gguf" setelah operasi selesai); hanya hasil GGUF yang diunduh.
- Kuantisasi model yang sudah terkuantisasi (mis. Q4_K_M ke Q5_K_M) sebelumnya selalu ditolak `llama-quantize` tanpa penjelasan; kini ada saklar eksplisit.
- Adapter LoRA hasil unduhan trainer tersimpan di folder model dasar sehingga muncul di daftar model dan bisa diaktifkan sebagai model dasar. Kini disimpan di `models/loras/`; adapter lama yang nyasar dipindahkan otomatis, dan adapter tidak bisa lagi dipilih/diimpor sebagai model dasar (diperiksa juga di preflight engine).
- Adapter hasil unduhan tidak lagi dipasang membabi buta: dipasang hanya bila cocok dengan model aktif, bila tidak berkas tetap tersimpan dan alasannya ditampilkan.
- Adapter yang gagal dimuat (mis. model dasar diganti) tidak lagi mematikan seluruh chat: model jalan tanpa adapter dan pengguna diberi peringatan.
- Native: API LoRA lama bersifat aditif, sehingga memasang adapter kedua menumpuk di atas yang pertama. Kini adapter aktif selalu digantikan, adapter di-cache per path (tidak membaca ulang berkas), dan kegagalan memuat tidak mengubah adapter aktif. Jumlah adapter berbeda per sesi model dibatasi 4 karena RAM-nya baru bebas bersama model.
- `EngineFactory.key` tidak lagi memuat path/skala adapter: mengganti adapter tidak memicu muat ulang model.
- `model/lora.json` menolak skala di luar 0–4.

### Batasan
- Satu adapter aktif pada satu waktu (belum ada penumpukan beberapa adapter).
- Kode LoRA baru belum dikompilasi/dijalankan di perangkat: JNI memakai `llama_clear_adapter_lora` (API lama) / `llama_set_adapters_lora(ctx, nullptr, 0, nullptr)` (API baru); bila build gagal, perbaiki di `llama_compat.h`.
- Model lokal yang diimpor dari berkas tanpa informasi asal tidak dapat diperiksa untuk pembaruan HF sampai repo sumbernya ditautkan.
- Kuantisasi dan operasi perubahan bobot memerlukan server ModelOps HTTPS yang sudah disiapkan pada halaman Latih; operasi berjalan remote, bukan di ponsel. Tidak ada editor byte-level atau training bobot penuh di perangkat.

## [0.3.8] - 2026-11-25

### Ditambahkan
- Release APK memakai jalur OTA GitHub Releases: aplikasi memeriksa versi terbaru saat dibuka, mengunduh APK baru, dan meneruskannya ke installer Android tanpa menghapus aplikasi atau data pengguna.
- Model **Froged N1** tetap dikirim di luar APK melalui Hugging Face Model Hub; perubahan ukuran/revisi model tidak lagi mengubah ukuran APK.
- Metadata model dilacak melalui revision, ukuran, dan SHA-256 sehingga model baru dapat diverifikasi sebelum dipakai.

## [0.3.7] - 2026-11-25

### Ditambahkan
- Menambahkan model **Froged N1 (Qwen2.5 0.5B)** ke katalog Model Hub.
- Menambahkan tautan repository Hugging Face dan unduhan langsung file GGUF Q4_K_M.

## [0.3.6] - 2026-11-25

### Diperbaiki
- Mengembalikan izin executable pada Gradle wrapper root dan Android agar perintah build/test CI tidak gagal dengan `Permission denied`.
- Mengembalikan gitlink submodule `llama.cpp` yang hilang, sehingga checkout CI memperoleh source native yang dibutuhkan CMake dan APK.
- Unduhan model Hugging Face kini memakai aliran HTTP Range berurutan untuk semua ukuran file. Ini mempertahankan berkas parsial yang kontigu sehingga jeda/resume tidak menganggap file prealokasi berisi segmen lengkap.
- Memperjelas nama konstanta namespace SharedPreferences arsip percakapan agar secret scanner tidak menganggapnya kredensial; aturan pemindaian tetap aktif.
- Mendeklarasikan tipe `dataSync` untuk service foreground WorkManager di manifest modul Hugging Face agar lulus Android lint.

## [0.3.5] - 2026-11-25

### Ditambahkan
- **Validasi native sebelum model dimuat** (`NativeCheck`, `EnginePreflight`): APK diperiksa apakah memuat `libneuron_llama.so` dan untuk ABI apa, dicocokkan dengan ABI perangkat dan proses (32/64-bit), header ELF berkas hasil ekstraksi dicek, dan sambungan JNI diuji lewat `nativeSystemInfo()`. Berkas model dicek (ada, `.gguf`, tidak terpotong, header `GGUF`) dan perkiraan RAM (model + KV cache) dibandingkan dengan `MemAvailable`.
- **Error dibedakan per jenis**: `ENGINE_NATIVE`, `ENGINE_MODEL`, `ENGINE_RAM`, `ENGINE_CONTEXT`, `ENGINE_CANCELLED` (kode PlatformException dari Kotlin, pesan native diberi tag `[MODEL]`/`[RAM]`/`[CONTEXT]`/`[NATIVE]`). `friendlyError` menampilkan kategori berbeda untuk tiap kode. Generate yang terhenti karena model dilepas kini dilaporkan sebagai `ENGINE_CANCELLED`, bukan tampak sebagai jawaban selesai.
- **Pembatas riwayat chat** (`HistoryLimiter`): jumlah pesan (maks 16) dan perkiraan token terhadap `contextLength` yang dimuat; pesan terlama dibuang lebih dulu, pemangkasan dilaporkan ke UI, pesan tunggal yang terlalu panjang ditolak dengan error konteks. Riwayat di memori Flutter juga dibatasi (40 pesan).
- **Peringatan di UI chat** (event `notice` pada `neuron/chat`): RAG dimatikan, template ChatML dipakai sebagai cadangan, riwayat dipangkas. Peringatan template juga muncul saat model dijalankan dari Model Hub.
- **Notifikasi konfigurasi API lama**: `engine.mode "API"`, `baseUrl`, `apiKey`, `model` di `project.json`, atau kunci API tersimpan, ditemukan dan dibuang dengan pemberitahuan sekali; menyimpan `engine/api.json` berisi konfigurasi API memunculkan peringatan bahwa isinya diabaikan.

### Diubah
- **RAG di chat mati secara bawaan** (pengujian awal). Dokumen dan indeks tidak dihapus; nyalakan lewat Pengaturan → "RAG di chat".
- Fallback ChatML tetap ada, tetapi selalu disertai peringatan (sebelumnya hanya `Log.w`).

### Diperbaiki
- Handle native tidak lagi bocor bila memuat LoRA gagal setelah model termuat; `nativeLoad() == 0` divalidasi eksplisit.
- `unload()` yang menyela di antara pembacaan handle dan lock generate tidak lagi bisa memakai memori yang sudah dibebaskan; `embed()` menolak model yang belum dimuat alih-alih memanggil native dengan handle kosong.
- Komentar/jembatan yang masih menyiratkan permintaan HTTP/API dibersihkan.

## [0.3.4] - 2026-11-24

### Diperbaiki
- Menyertakan submodule `ggml-org/llama.cpp` agar library native tersedia saat build APK release.

## [0.3.3] - 2026-11-24

### Diperbaiki
- Menambahkan pemeriksaan lifecycle sebelum dialog pengaturan model dibuka.

## [0.3.2] - 2026-11-24

### Diperbaiki
- Menuntaskan lint Flutter yang menghalangi verifikasi dan build APK release.

## [0.3.1] - 2026-11-24

### Diperbaiki
- Memperbaiki lint Flutter dan pemeriksaan async context agar workflow verifikasi serta build release APK dapat berjalan.

## [0.3.0] - 2026-11-24

### Ditambahkan
- **Alur kerja 4 langkah** (Pilih model → Unduh → Jalankan → Chat & edit): indikator status di Model Hub yang mengikuti kondisi model secara langsung, ditampilkan juga di tampilan kosong Chat beserta contoh perintah cepat (Ringkas teks, Jelaskan sederhana, Bantu kode). Logika langkah diuji di `flow_stepper_test.dart`.
- **Model Hub**: katalog model GGUF kurasi, pemilihan file otomatis, unduh → aktif → chat dalam satu alur.
- **Jalankan/Hentikan model** (muat ke memori atau lepas), peringatan RAM rendah, dan **Pengaturan model**
  (prompt sistem dengan preset, temperature, maks token, panjang konteks). Ganti nama model terpasang.
- **Onboarding** pertama kali: cek perangkat, rekomendasi model sesuai RAM, unduh otomatis.
- Chat: render format ringan dan **blok kode dengan tombol Salin**, kecepatan jawaban (token/dtk), **Edit** pesan,
  **Ulangi** jawaban, **Salin**, dan **Perbaiki** (membuka Copilot dengan jawaban itu).
- **Riwayat percakapan** dengan judul otomatis; percakapan lama diarsipkan saat memulai yang baru.
- Pemulihan status unduhan model saat halaman Model Hub dibuka kembali.
- Pesan error yang bisa ditindaklanjuti (jaringan, penyimpanan, memori, akses, library native).
- Halaman **Tentang** dengan versi dan identitas pembuat.

### Dihapus
- **Mode API / model online.** Chat kini hanya memakai model GGUF lokal (llama.cpp). `RemoteApiEngine`, kolom Base URL,
  model, dan API key di dialog Pengaturan, serta `saveEngine`/`setEngineMode` di bridge sudah dihapus.
  `project.json` lama bernilai `"API"` tetap terbaca dan dianggap `LOCAL`; kunci API lama di penyimpanan
  terenkripsi dibuang saat aplikasi dibuka. Dialog Pengaturan menampilkan model aktif dan status runtime native.
- Sisa kode/teks mode API dibersihkan: `ProjectBridge.indexKnowledge` tidak lagi memakai `engine.apiKey` (penyebab error kompilasi), pesan error/Copilot tidak lagi menyarankan "mode API", dokumentasi dan README hanya menyebut engine lokal.
- **Server lokal OpenAI-compatible** (modul `:server`, halaman Server, `LocalServerService`, izin FGS specialUse) dihapus. Aplikasi tidak lagi membuka endpoint API apa pun; alurnya: unduh GGUF (Model Hub / Hugging Face) → pilih → chat / Copilot / edit.
- Indeks RAG lama mungkin dibangun ulang sekali karena label mesin tidak lagi memuat nama model API.

### Diubah
- Copilot mengulang satu kali bila model lokal membalas JSON rusak, dan membuang blok `<think>`.
- `EditHistory` dipindah dari `main.dart` ke `edit_history.dart`.

### Catatan
- Perubahan ini belum diverifikasi di perangkat. Jalankan CI dan checklist di `docs/VERIFICATION_CHECKLIST.md`
  (bagian "Model Hub, chat, dan onboarding") sebelum rilis stabil.

## [0.2.8] - sebelumnya
- Lihat `docs/STATUS.md` dan `docs/RELEASE.md`.

## Unreleased
- Privasi per model: dialog Fitur punya tombol "Edit privasi model". Alurnya: pilih model lokal yang terpasang, kartu info menampilkan file yang diedit (`<model>.gguf.privacy.json`, di samping model), status model (aktif atau belum), dan repo asal unduhan; ambil `privacy.json` dari repo asal (bawaan `bytecode66/Froged_N1`), edit, lalu "Simpan saja" atau "Simpan & pakai" (guardrail digabung tanpa duplikat; hanya untuk model aktif). Berkas privasi ikut terhapus saat model dihapus. Parser (`PrivacyPolicy`) toleran terhadap skema; belum diuji build/perangkat.
