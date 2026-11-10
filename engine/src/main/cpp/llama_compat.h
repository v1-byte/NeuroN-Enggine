#pragma once
// Semua bagian yang berubah antar versi llama.cpp dikumpulkan di sini.
// Jika build gagal setelah update llama.cpp, biasanya cukup memperbaiki file ini.
// Default = API baru (flash_attn_type + llama_memory_*). Untuk llama.cpp lama definisikan NEURON_OLD_LLAMA_API.
// Untuk API LoRA baru (llama_set_adapters_lora) definisikan NEURON_NEW_LORA_API.
#include <string>
#include "llama.h"

// Biasanya dideteksi otomatis oleh CMakeLists.txt. NEURON_OLD_LLAMA_API = kompatibilitas lama (keduanya).
#ifdef NEURON_OLD_LLAMA_API
#  ifndef NEURON_OLD_FLASH_API
#    define NEURON_OLD_FLASH_API
#  endif
#  ifndef NEURON_OLD_KV_API
#    define NEURON_OLD_KV_API
#  endif
#endif

inline void neuron_set_flash_attn(llama_context_params& p, bool on) {
#ifdef NEURON_OLD_FLASH_API
    p.flash_attn = on;
#else
    p.flash_attn_type = on ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED;
#endif
}

inline void neuron_clear_kv(llama_context* ctx) {
#ifdef NEURON_OLD_KV_API
    llama_kv_cache_clear(ctx);
#else
    llama_memory_clear(llama_get_memory(ctx), true);
#endif
}

// Hapus entri KV dari posisi `from` sampai akhir (sequence 0). false = tidak didukung (mis. model recurrent/SWA).
inline bool neuron_kv_trim(llama_context* ctx, int from) {
#ifdef NEURON_OLD_KV_API
    return llama_kv_cache_seq_rm(ctx, 0, from, -1);
#else
    return llama_memory_seq_rm(llama_get_memory(ctx), 0, from, -1);
#endif
}

// Context shift: buang n_discard token setelah n_keep, geser sisanya ke kiri. false = model tidak mendukung.
inline bool neuron_kv_can_shift(llama_context* ctx) {
#ifdef NEURON_OLD_KV_API
    return llama_kv_cache_can_shift(ctx);
#else
    return llama_memory_can_shift(llama_get_memory(ctx));
#endif
}
inline void neuron_kv_shift(llama_context* ctx, int n_keep, int n_discard) {
#ifdef NEURON_OLD_KV_API
    llama_kv_cache_seq_rm(ctx, 0, n_keep, n_keep + n_discard);
    llama_kv_cache_seq_add(ctx, 0, n_keep + n_discard, -1, -n_discard);
#else
    llama_memory_t m = llama_get_memory(ctx);
    llama_memory_seq_rm(m, 0, n_keep, n_keep + n_discard);
    llama_memory_seq_add(m, 0, n_keep + n_discard, -1, -n_discard);
#endif
}

inline int neuron_piece(const llama_vocab* v, llama_token t, char* buf, int n) {
    return llama_token_to_piece(v, t, buf, n, /*lstrip*/ 0, /*special*/ true);
}

inline bool neuron_apply_lora(llama_model* model, llama_context* ctx, const char* path, float scale, std::string& err) {
    llama_adapter_lora* ad = llama_adapter_lora_init(model, path);
    if (!ad) { err = std::string("Gagal memuat LoRA: ") + path; return false; }
#ifdef NEURON_NEW_LORA_API
    llama_adapter_lora* arr[1] = {ad};
    float sc[1] = {scale};
    llama_set_adapters_lora(ctx, arr, 1, sc);
#else
    if (llama_set_adapter_lora(ctx, ad, scale) != 0) { err = "Gagal mengaktifkan LoRA"; return false; }
#endif
    return true;   // adapter dibebaskan otomatis bersama model
}
