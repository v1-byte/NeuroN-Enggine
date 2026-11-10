// JNI NeuroN Engine <-> llama.cpp. Ditulis terhadap API llama.cpp yang memakai llama_vocab / llama_memory.
// Belum dikompilasi/diuji: lihat docs/NATIVE.md dan llama_compat.h bila ada error API.
#include <jni.h>
#include <android/log.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include "llama.h"
#include "llama_compat.h"

#define TAG "NeuroN"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

// Teruskan log internal llama.cpp/ggml ke logcat (tag NeuroN-llama) supaya error load terlihat di perangkat.
static void llama_log_cb(ggml_log_level level, const char* text, void*) {
    int prio = level == GGML_LOG_LEVEL_ERROR ? ANDROID_LOG_ERROR
             : level == GGML_LOG_LEVEL_WARN  ? ANDROID_LOG_WARN : ANDROID_LOG_INFO;
    __android_log_write(prio, "NeuroN-llama", text);
}

namespace {

struct Handle {
    llama_model* model = nullptr;
    llama_context* ctx = nullptr;
    const llama_vocab* vocab = nullptr;
    int n_ctx = 0, n_batch = 0, threads = 4;
    std::atomic<bool> cancel{false};
    std::vector<llama_token> cached;   // token yang saat ini ada di KV cache (urut dari posisi 0)
};
std::once_flag g_init;

void throw_java(JNIEnv* env, const std::string& msg) {
    jclass c = env->FindClass("java/lang/RuntimeException");
    env->ThrowNew(c, msg.c_str());
}
std::string jstr(JNIEnv* env, jstring s) {
    if (!s) return {};
    const char* c = env->GetStringUTFChars(s, nullptr);
    std::string r(c);
    env->ReleaseStringUTFChars(s, c);
    return r;
}
// Teks dikirim sebagai byte UTF-8 (bukan jstring) agar emoji/karakter non-BMP aman.
std::string bytes_to_string(JNIEnv* env, jbyteArray a) {
    if (!a) return {};
    jsize n = env->GetArrayLength(a);
    std::string s(static_cast<size_t>(n), '\0');
    if (n) env->GetByteArrayRegion(a, 0, n, reinterpret_cast<jbyte*>(s.data()));
    return s;
}
jbyteArray string_to_bytes(JNIEnv* env, const char* p, int n) {
    jbyteArray a = env->NewByteArray(n);
    env->SetByteArrayRegion(a, 0, n, reinterpret_cast<const jbyte*>(p));
    return a;
}
ggml_type kv_type(const std::string& s) {
    if (s == "q8_0") return GGML_TYPE_Q8_0;
    if (s == "q4_0") return GGML_TYPE_Q4_0;
    return GGML_TYPE_F16;
}
std::vector<llama_token> tokenize(const llama_vocab* v, const std::string& s, bool add_special) {
    int n = -llama_tokenize(v, s.c_str(), (int)s.size(), nullptr, 0, add_special, true);
    std::vector<llama_token> t(std::max(n, 0));
    if (n <= 0) return t;
    int r = llama_tokenize(v, s.c_str(), (int)s.size(), t.data(), (int)t.size(), add_special, true);
    if (r < 0) t.clear(); else t.resize(r);
    return t;
}
}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL Java_com_neuron_engine_LlamaCppEngine_nativeLoad(
        JNIEnv* env, jobject, jstring jpath, jint nCtx, jint threads, jint gpuLayers, jint batch,
        jboolean flash, jstring jkv, jint ropeType, jfloat ropeScale) {
    std::call_once(g_init, [] { llama_log_set(llama_log_cb, nullptr); llama_backend_init(); });
    std::string path = jstr(env, jpath), kv = jstr(env, jkv);

    llama_model_params mp = llama_model_default_params();
#ifndef NEURON_HAS_VULKAN
    if (gpuLayers > 0) LOGI("numGpuLayers=%d diabaikan: library dibuild tanpa Vulkan (-PwithVulkan)", gpuLayers);
    gpuLayers = 0;
#endif
    mp.n_gpu_layers = gpuLayers;
    mp.use_mmap = true;
    llama_model* model = llama_model_load_from_file(path.c_str(), mp);
    if (!model) { throw_java(env, "Gagal memuat model (file rusak / bukan GGUF / RAM kurang): " + path); return 0; }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = nCtx;
    cp.n_batch = batch;
    cp.n_ubatch = std::min<int>(batch, 512);
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    neuron_set_flash_attn(cp, flash);
    cp.type_k = kv_type(kv);
    cp.type_v = kv_type(kv);
    if (ropeType == 1) cp.rope_scaling_type = LLAMA_ROPE_SCALING_TYPE_LINEAR;
    else if (ropeType == 2) cp.rope_scaling_type = LLAMA_ROPE_SCALING_TYPE_YARN;
    if (ropeType != 0 && ropeScale > 0.f) cp.rope_freq_scale = ropeScale;

    llama_context* ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        llama_model_free(model);
        throw_java(env, "Gagal membuat context (RAM kurang? turunkan contextLength / kvCacheType)");
        return 0;
    }
    auto* H = new Handle();
    H->model = model; H->ctx = ctx; H->vocab = llama_model_get_vocab(model);
    H->n_ctx = nCtx; H->n_batch = batch; H->threads = threads;
    LOGI("model dimuat: ctx=%d batch=%d threads=%d", nCtx, batch, threads);
    return reinterpret_cast<jlong>(H);
}

JNIEXPORT void JNICALL Java_com_neuron_engine_LlamaCppEngine_nativeLoadLora(
        JNIEnv* env, jobject, jlong h, jstring jpath, jfloat scale) {
    auto* H = reinterpret_cast<Handle*>(h);
    if (!H) { throw_java(env, "Model belum dimuat"); return; }
    std::string err;
    if (!neuron_apply_lora(H->model, H->ctx, jstr(env, jpath).c_str(), scale, err)) throw_java(env, err);
    neuron_clear_kv(H->ctx); H->cached.clear();
}

JNIEXPORT jbyteArray JNICALL Java_com_neuron_engine_LlamaCppEngine_nativeApplyTemplate(
        JNIEnv* env, jobject, jlong h, jobjectArray roles, jobjectArray contents, jbyteArray jtmpl, jboolean addAss) {
    auto* H = reinterpret_cast<Handle*>(h);
    jsize n = env->GetArrayLength(roles);
    std::vector<std::string> r(n), c(n);
    std::vector<llama_chat_message> msgs(n);
    size_t total = 1024;
    for (jsize i = 0; i < n; i++) {
        auto ra = (jbyteArray)env->GetObjectArrayElement(roles, i);
        auto ca = (jbyteArray)env->GetObjectArrayElement(contents, i);
        r[i] = bytes_to_string(env, ra); c[i] = bytes_to_string(env, ca);
        env->DeleteLocalRef(ra); env->DeleteLocalRef(ca);
        msgs[i] = {r[i].c_str(), c[i].c_str()};
        total += (r[i].size() + c[i].size()) * 2 + 64;
    }
    std::string t = bytes_to_string(env, jtmpl);
    // Catatan: hanya template yang dikenali llama.cpp (ChatML, Llama, Gemma, dll). Jinja bebas tidak didukung.
    const char* tp = t.empty() ? llama_model_chat_template(H->model, nullptr) : t.c_str();
    if (!tp) return nullptr;
    std::vector<char> buf(total);
    int out = llama_chat_apply_template(tp, msgs.data(), msgs.size(), addAss, buf.data(), (int)buf.size());
    if (out > (int)buf.size()) {
        buf.resize(out);
        out = llama_chat_apply_template(tp, msgs.data(), msgs.size(), addAss, buf.data(), (int)buf.size());
    }
    if (out < 0) return nullptr;
    return string_to_bytes(env, buf.data(), out);
}

JNIEXPORT void JNICALL Java_com_neuron_engine_LlamaCppEngine_nativeGenerate(
        JNIEnv* env, jobject, jlong h, jbyteArray jprompt, jfloat temp, jfloat topP, jint topK, jfloat minP,
        jfloat repeat, jfloat presence, jfloat freq, jint maxTokens, jlong seed,
        jintArray biasIds, jfloatArray biasVals, jobject cb) {
    auto* H = reinterpret_cast<Handle*>(h);
    H->cancel = false;
    std::string prompt = bytes_to_string(env, jprompt);

    // Tokenisasi: template chat sudah memuat token khusus; tambahkan BOS hanya jika model butuh & belum ada.
    std::vector<llama_token> toks = tokenize(H->vocab, prompt, false);
    if (llama_vocab_get_add_bos(H->vocab) && (toks.empty() || toks[0] != llama_vocab_bos(H->vocab)))
        toks.insert(toks.begin(), llama_vocab_bos(H->vocab));
    if (toks.empty()) { throw_java(env, "Prompt kosong / gagal tokenisasi"); return; }
    // Prompt terlalu panjang: pertahankan awal (system prompt) + ekor (pesan terbaru), buang bagian tengah.
    const int n_keep = std::min(128, H->n_ctx / 4);
    {
        const int reserve = std::max(16, std::min((int)maxTokens, H->n_ctx / 4));
        const int budget = H->n_ctx - 1 - reserve;
        if ((int)toks.size() > budget) {
            if (budget <= n_keep) { throw_java(env, "contextLength terlalu kecil untuk prompt ini"); return; }
            int tail = budget - n_keep;
            LOGI("prompt %zu token > batas %d: bagian tengah dibuang", toks.size(), budget);
            toks.erase(toks.begin() + n_keep, toks.end() - tail);
        }
    }

    // Sampler: logit_bias -> penalties -> top_k -> top_p -> min_p -> temp -> dist(seed)
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> smpl(
        llama_sampler_chain_init(llama_sampler_chain_default_params()), &llama_sampler_free);
    jsize nb = biasIds ? env->GetArrayLength(biasIds) : 0;
    if (nb > 0) {
        std::vector<jint> ids(nb); std::vector<jfloat> vals(nb);
        env->GetIntArrayRegion(biasIds, 0, nb, ids.data());
        env->GetFloatArrayRegion(biasVals, 0, nb, vals.data());
        std::vector<llama_logit_bias> bias(nb);
        for (jsize i = 0; i < nb; i++) bias[i] = {ids[i], vals[i]};
        llama_sampler_chain_add(smpl.get(), llama_sampler_init_logit_bias(llama_vocab_n_tokens(H->vocab), nb, bias.data()));
    }
    if (repeat != 1.f || freq != 0.f || presence != 0.f)
        llama_sampler_chain_add(smpl.get(), llama_sampler_init_penalties(64, repeat, freq, presence));
    const bool penalties = (repeat != 1.f || freq != 0.f || presence != 0.f);
    if (temp <= 0.f) {
        llama_sampler_chain_add(smpl.get(), llama_sampler_init_greedy());
    } else {
        if (topK > 0) llama_sampler_chain_add(smpl.get(), llama_sampler_init_top_k(topK));
        if (topP < 1.f) llama_sampler_chain_add(smpl.get(), llama_sampler_init_top_p(topP, 1));
        if (minP > 0.f) llama_sampler_chain_add(smpl.get(), llama_sampler_init_min_p(minP, 1));
        llama_sampler_chain_add(smpl.get(), llama_sampler_init_temp(temp));
        llama_sampler_chain_add(smpl.get(), llama_sampler_init_dist(seed < 0 ? LLAMA_DEFAULT_SEED : (uint32_t)seed));
    }

    // Penalti repetisi juga harus "melihat" ekor prompt (bukan hanya token yang dihasilkan).
    if (penalties) {
        int from = std::max(0, (int)toks.size() - 64);
        for (int i = from; i < (int)toks.size(); i++) llama_sampler_accept(smpl.get(), toks[i]);
    }

    // Prefix cache: pakai ulang KV untuk awalan prompt yang sama dengan permintaan sebelumnya.
    size_t common = 0;
    while (common < H->cached.size() && common < toks.size() && H->cached[common] == toks[common]) common++;
    if (common >= toks.size()) common = toks.size() - 1;   // sisakan 1 token agar ada logits untuk sampling
    if (common == 0 || !neuron_kv_trim(H->ctx, (int)common)) {
        neuron_clear_kv(H->ctx);
        common = 0;
    }
    H->cached.resize(common);
    LOGI("prefill: %zu token, dipakai ulang dari cache: %zu", toks.size(), common);

    const int nbatch = std::max(1, H->n_batch);
    for (int i = (int)common; i < (int)toks.size(); i += nbatch) {
        int n = std::min(nbatch, (int)toks.size() - i);
        if (H->cancel) return;   // cached hanya berisi token yang sudah ter-decode: tetap konsisten
        if (llama_decode(H->ctx, llama_batch_get_one(toks.data() + i, n)) != 0) {
            neuron_clear_kv(H->ctx); H->cached.clear();
            throw_java(env, "llama_decode gagal saat memproses prompt"); return;
        }
        H->cached.insert(H->cached.end(), toks.begin() + i, toks.begin() + i + n);
    }

    jclass cls = env->GetObjectClass(cb);
    jmethodID mid = env->GetMethodID(cls, "onToken", "([B)Z");
    if (!mid) { env->ExceptionClear(); throw_java(env, "Callback onToken tidak ditemukan"); return; }
    int n_past = (int)toks.size();
    for (int i = 0; i < maxTokens && !H->cancel; i++) {
        if (n_past >= H->n_ctx - 1) {   // context penuh: geser (buang setengah riwayat setelah n_keep) atau berhenti
            if (!neuron_kv_can_shift(H->ctx) || n_past - n_keep < 2) break;
            int discard = (n_past - n_keep) / 2;
            neuron_kv_shift(H->ctx, n_keep, discard);
            if ((int)H->cached.size() >= n_keep + discard)
                H->cached.erase(H->cached.begin() + n_keep, H->cached.begin() + n_keep + discard);
            n_past -= discard;
            LOGI("context shift: buang %d token", discard);
        }
        llama_token t = llama_sampler_sample(smpl.get(), H->ctx, -1);   // sample() sudah memanggil accept()
        if (llama_vocab_is_eog(H->vocab, t)) break;

        std::string piece(256, '\0');
        int len = neuron_piece(H->vocab, t, piece.data(), (int)piece.size());
        if (len < 0) { piece.resize(-len); len = neuron_piece(H->vocab, t, piece.data(), (int)piece.size()); }
        piece.resize(std::max(len, 0));

        jbyteArray arr = string_to_bytes(env, piece.data(), (int)piece.size());
        jboolean cont = env->CallBooleanMethod(cb, mid, arr);
        env->DeleteLocalRef(arr);
        if (env->ExceptionCheck() || !cont) break;

        if (llama_decode(H->ctx, llama_batch_get_one(&t, 1)) != 0) {
            neuron_clear_kv(H->ctx); H->cached.clear();
            throw_java(env, "llama_decode gagal saat generate"); return;
        }
        H->cached.push_back(t);
        n_past++;
    }
}

JNIEXPORT jfloatArray JNICALL Java_com_neuron_engine_LlamaCppEngine_nativeEmbed(
        JNIEnv* env, jobject, jlong h, jbyteArray jtext) {
    auto* H = reinterpret_cast<Handle*>(h);
    std::vector<llama_token> toks = tokenize(H->vocab, bytes_to_string(env, jtext), true);
    if (toks.empty()) { throw_java(env, "Teks kosong"); return nullptr; }
    if ((int)toks.size() > H->n_ctx) toks.resize(H->n_ctx);

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = (uint32_t)toks.size() + 8;
    cp.n_batch = cp.n_ubatch = (uint32_t)toks.size();   // model embedding non-kausal: seluruh teks harus 1 ubatch
    cp.n_threads = cp.n_threads_batch = H->threads;
    cp.embeddings = true;
    llama_context* ectx = llama_init_from_model(H->model, cp);
    if (!ectx) { throw_java(env, "Gagal membuat context embedding"); return nullptr; }

    jfloatArray result = nullptr;
    if (llama_decode(ectx, llama_batch_get_one(toks.data(), (int)toks.size())) == 0) {
        const float* e = llama_get_embeddings_seq(ectx, 0);
        if (!e) e = llama_get_embeddings_ith(ectx, -1);   // model tanpa pooling: pakai token terakhir
        int d = llama_model_n_embd(H->model);
        if (e) {
            std::vector<float> v(e, e + d);
            double s = 0; for (float x : v) s += (double)x * x;
            float inv = s > 0 ? (float)(1.0 / std::sqrt(s)) : 1.f;
            for (float& x : v) x *= inv;
            result = env->NewFloatArray(d);
            env->SetFloatArrayRegion(result, 0, d, v.data());
        }
    }
    llama_free(ectx);
    if (!result) throw_java(env, "Embedding gagal (model ini mungkin tidak mendukung embedding)");
    return result;
}

JNIEXPORT jstring JNICALL Java_com_neuron_engine_LlamaCppEngine_nativeSystemInfo(JNIEnv* env, jobject) {
    std::call_once(g_init, [] { llama_log_set(llama_log_cb, nullptr); llama_backend_init(); });
    std::string s = llama_print_system_info();
#ifdef NEURON_HAS_VULKAN
    s += " | VULKAN=on";
#else
    s += " | VULKAN=off";
#endif
    return env->NewStringUTF(s.c_str());
}

JNIEXPORT void JNICALL Java_com_neuron_engine_LlamaCppEngine_nativeCancel(JNIEnv*, jobject, jlong h) {
    if (h) reinterpret_cast<Handle*>(h)->cancel = true;
}

JNIEXPORT void JNICALL Java_com_neuron_engine_LlamaCppEngine_nativeFree(JNIEnv*, jobject, jlong h) {
    auto* H = reinterpret_cast<Handle*>(h);
    if (!H) return;
    llama_free(H->ctx);
    llama_model_free(H->model);
    delete H;
}

}  // extern "C"
