import 'dart:convert';
import 'package:flutter/services.dart';

/// Jembatan ke engine Kotlin:
///  - neuron/project  -> android/app/src/main/kotlin/com/neuron/engine/ProjectBridge.kt
///  - neuron/chat     -> android/app/src/main/kotlin/com/neuron/engine/NeuronBridge.kt
const _project = MethodChannel('neuron/project');
const _chat = EventChannel('neuron/chat');
const _update = MethodChannel('neuron/update');

/// Pengaturan engine: hanya mesin lokal (llama.cpp). Tidak ada Base URL atau API key.
class EngineSettings {
  const EngineSettings({this.model = '', this.mode = 'LOCAL', this.modelPath = '', this.nativeAvailable = false, this.legacyApi = false});
  final String model;
  final String mode;
  final String modelPath;
  final bool nativeAvailable;

  /// Konfigurasi API lama ditemukan di proyek dan diabaikan (hanya mode lokal yang didukung). Tampilkan sekali, lalu [Bridge.ackLegacyApi].
  final bool legacyApi;
}

class FeatureState {
  const FeatureState(
      {this.tools = false, this.words = const [], this.regex = const []});
  final bool tools;
  final List<String> words;
  final List<String> regex;
}

/// Hasil menyimpan privasi satu model. [words]/[regex] = isi guardrail sesudah digabung (kosong bila [used] false).
class PrivacyApplied {
  const PrivacyApplied(
      {this.used = false,
      this.file = '',
      this.words = const [],
      this.regex = const [],
      this.warnings = const []});
  final bool used;
  final String file;
  final List<String> words;
  final List<String> regex;
  final List<String> warnings;
}

class ChatHistory {
  const ChatHistory({this.lines = const [], this.conversation = const []});
  final List<Map<String, String>> lines;
  final List<Map<String, String>> conversation;
}

/// Semua panggilan ke engine. Berkas proyek dibaca dan ditulis lewat Bridge, bukan dari path lokal.
class Bridge {
  static Future<List<String>> openPaths() async {
    final m = await _project.invokeMapMethod<String, dynamic>('open');
    return List<String>.from((m?['paths'] as List?) ?? const []);
  }

  static Future<String> read(String path) async =>
      (await _project.invokeMethod<String>('read', {'path': path})) ?? '';

  /// Melempar PlatformException bila validasi di VirtualTree menolak teks.
  /// Mengembalikan peringatan (mis. konfigurasi API diabaikan) bila berkas tersimpan tetapi sebagian isinya tidak dipakai.
  static Future<String?> write(String path, String text) async {
    final r = await _project.invokeMapMethod<String, dynamic>('write', {'path': path, 'text': text});
    final w = r?['warning'];
    return w is String && w.isNotEmpty ? w : null;
  }

  static Future<EngineSettings> loadEngine() async {
    final m = await _project.invokeMapMethod<String, dynamic>('loadEngine');
    return EngineSettings(
      model: m?['model'] as String? ?? '',
      mode: m?['mode'] as String? ?? 'LOCAL',
      modelPath: m?['modelPath'] as String? ?? '',
      nativeAvailable: m?['nativeAvailable'] == true,
      legacyApi: m?['legacyApi'] == true,
    );
  }

  static Future<void> ackLegacyApi() async {
    await _project.invokeMethod<dynamic>('ackLegacyApi');
  }

  /// Saklar runtime chat. `ragInChat` mati secara bawaan (pengujian awal tanpa RAG).
  static Future<bool> ragInChat() async {
    final m = await _project.invokeMapMethod<String, dynamic>('chatFlags');
    return m?['ragInChat'] == true;
  }

  static Future<void> setRagInChat(bool enabled) async {
    await _project.invokeMethod<dynamic>('setRagInChat', {'enabled': enabled});
  }

  static Future<FeatureState> loadFeatures() async {
    final m = await _project.invokeMapMethod<String, dynamic>('loadFeatures');
    return FeatureState(
      tools: m?['tools'] == true,
      words: List<String>.from((m?['words'] as List?) ?? const []),
      regex: List<String>.from((m?['regex'] as List?) ?? const []),
    );
  }

  static Future<void> setTools(bool enabled) async {
    await _project.invokeMethod<dynamic>('setTools', {'enabled': enabled});
  }

  static Future<void> saveGuardrails(
      List<String> words, List<String> regex) async {
    await _project.invokeMethod<dynamic>(
        'saveGuardrails', {'words': words, 'regex': regex});
  }

  /// Model lokal yang bisa dipilih untuk diedit privasinya (terunduh, terimpor, atau aktif).
  static Future<List<Map<String, dynamic>>> privacyModels() async =>
      (await _project.invokeListMethod<dynamic>('privacyModels') ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  /// Salinan privasi milik satu model: text, exists, file, source.
  static Future<Map<String, dynamic>> privacyLoad(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'privacyLoad', {'path': path}) ??
          const {});

  /// Unduh privacy.json dari repo asal model (belum disimpan): text, source.
  static Future<Map<String, dynamic>> privacyFetch(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'privacyFetch', {'path': path}) ??
          const {});

  /// Simpan privasi ke berkas model yang dipilih. [use] true: juga digabung ke guardrail (hanya model aktif).
  static Future<PrivacyApplied> privacyApply(String path, String text,
      {bool use = false}) async {
    final m = await _project.invokeMapMethod<String, dynamic>(
        'privacyApply', {'path': path, 'text': text, 'use': use});
    return PrivacyApplied(
      used: m?['used'] == true,
      file: m?['file'] as String? ?? '',
      words: List<String>.from((m?['words'] as List?) ?? const []),
      regex: List<String>.from((m?['regex'] as List?) ?? const []),
      warnings: List<String>.from((m?['warnings'] as List?) ?? const []),
    );
  }

  static Future<ChatHistory> loadChatHistory() async {
    final m =
        await _project.invokeMapMethod<String, dynamic>('loadChatHistory');
    List<Map<String, String>> rows(String key, String bodyKey) =>
        ((m?[key] as List?) ?? const [])
            .whereType<Map>()
            .map((row) => {
                  'role': row['role']?.toString() ?? '',
                  bodyKey: row[bodyKey]?.toString() ?? '',
                })
            .toList();
    return ChatHistory(
        lines: rows('lines', 'text'),
        conversation: rows('conversation', 'content'));
  }

  static Future<void> saveChatHistory(ChatHistory history) async {
    await _project.invokeMethod<dynamic>('saveChatHistory', {
      'lines': history.lines,
      'conversation': history.conversation,
    });
  }

  static Future<void> clearChatHistory() async {
    await _project.invokeMethod<dynamic>('clearChatHistory');
  }

  static Future<Map<String, dynamic>> setLocalModel(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'setLocalModel', {'path': path}) ??
          const {});
  /// Daftar model GGUF lokal. [hash] = false melewati SHA-256 yang belum ter-cache (jauh lebih cepat; dipakai Editor GGUF).
  static Future<List<Map<String, dynamic>>> localModels({bool hash = true}) async =>
      (await _project.invokeListMethod<dynamic>('localModels', {'hash': hash}) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  static Future<void> deleteLocalModel(String path) async {
    await _project.invokeMethod<dynamic>('deleteLocalModel', {'path': path});
  }
  /// Baca model GGUF secara total: metadata, ringkasan tensor (parameter, ukuran per tipe), dan hasil pemeriksaan integritas.
  static Future<Map<String, dynamic>> ggufInspect(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('ggufInspect', {'path': path}) ?? const {});

  /// Halaman tabel tensor: {total, matched, offset, items: [{name, shape, type, bytes, params, offset}]}.
  static Future<Map<String, dynamic>> ggufTensors(String path, {String query = '', int offset = 0, int limit = 100}) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'ggufTensors', {'path': path, 'query': query, 'offset': offset, 'limit': limit}) ??
          const {});

  /// Halaman isi array metadata (mis. tokenizer.ggml.tokens): {key, elemType, count, offset, items: [teks]}.
  static Future<Map<String, dynamic>> ggufArray(String path, String key, {int offset = 0, int limit = 100}) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'ggufArray', {'path': path, 'key': key, 'offset': offset, 'limit': limit}) ??
          const {});

  /// Parameter generate per model: {name, active, overrides, base, effective}. Kunci camelCase seperti ChatParams.
  static Future<Map<String, dynamic>> modelParamsGet(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('modelParamsGet', {'path': path}) ?? const {});

  /// Simpan penimpas (JSON objek; `{}` = hapus semuanya). Nilai tidak valid melempar PlatformException berisi pesannya.
  static Future<Map<String, dynamic>> modelParamsSave(String path, String paramsJson) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('modelParamsSave', {'path': path, 'params': paramsJson}) ?? const {});

  static Future<Map<String, dynamic>> modelParamsClear(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('modelParamsClear', {'path': path}) ?? const {});

  /// Uji cepat pada model aktif dengan nilai form (belum disimpan): {text, tokens, ms, tps, contextPinned}.
  static Future<Map<String, dynamic>> modelParamsTest(String path, String prompt, String paramsJson, {int maxTokens = 128}) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'modelParamsTest', {'path': path, 'prompt': prompt, 'params': paramsJson, 'maxTokens': maxTokens}) ??
          const {});

  /// Salin GGUF dari penyimpanan HP ke folder model NeuroN tanpa mengaktifkannya. Hasil: {path, name}.
  static Future<Map<String, dynamic>> importLocalModel(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('importLocalModel', {'path': path}) ?? const {});

  /// Ringkasan header GGUF (arsitektur, panjang konteks, dimensi, template chat, tipe file) untuk mengisi berkas Workspace.
  static Future<Map<String, dynamic>> localModelProfile(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('localModelProfile', {'path': path}) ?? const {});

  /// Menulis salinan baru model dengan metadata berubah. [edits]: {key, type, value, delete}. Model asli tidak diubah.
  static Future<Map<String, dynamic>> ggufSave(String path, List<Map<String, dynamic>> edits, {bool activate = false}) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'ggufSave', {'path': path, 'edits': edits, 'activate': activate}) ??
          const {});

  static Future<Map<String, dynamic>> ggufProgress() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('ggufProgress') ?? const {});

  static Future<void> ggufCancel() async {
    await _project.invokeMethod<dynamic>('ggufCancel');
  }

  static Future<Map<String, dynamic>> renameLocalModel(String path, String name) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('renameLocalModel', {'path': path, 'name': name}) ?? const {});
  static Future<Map<String, dynamic>> verifyLocalModel(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('verifyLocalModel', {'path': path}) ?? const {});
  static Future<Map<String, dynamic>> exportLocalModelMetadata(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('exportLocalModelMetadata', {'path': path}) ?? const {});
  static Future<Map<String, dynamic>> deviceHealth({int modelSize = 0}) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'deviceHealth', {'modelSize': modelSize}) ??
          const {});
  static Future<Map<String, dynamic>> activateLocalModel(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'activateLocalModel', {'path': path}) ??
          const {});
  static Future<Map<String, dynamic>> runModel() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('runModel') ?? const {});
  static Future<Map<String, dynamic>> unloadModel() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('unloadModel') ?? const {});
  static Future<Map<String, dynamic>> modelState() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('modelState') ?? const {});
  static Future<Map<String, dynamic>> addKnowledgeFile(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'addKnowledgeFile', {'path': path}) ??
          const {});
  static Future<Map<String, dynamic>> knowledgeState() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'knowledgeState') ??
          const {});
  static Future<Map<String, dynamic>> indexKnowledge() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'indexKnowledge') ??
          const {});
  static Future<void> saveHfToken(String token) async {
    await _project.invokeMethod<dynamic>('hfSaveToken', {'token': token});
  }
  static Future<List<Map<String, dynamic>>> hfSearch(String query, {String scope = 'all'}) async =>
      (await _project.invokeListMethod<dynamic>('hfSearch', {'query': query, 'scope': scope}) ??
              const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  static Future<List<Map<String, dynamic>>> hfFiles(String repo) async =>
      (await _project.invokeListMethod<dynamic>('hfFiles', {'repo': repo}) ??
              const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  static Future<Map<String, dynamic>> hfRevision(String repo) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('hfRevision', {'repo': repo}) ?? const {});
  static Future<void> trackLocalModelSource(String path, String repo, String revision) async {
    await _project.invokeMethod<dynamic>('trackLocalModelSource', {'path': path, 'repo': repo, 'revision': revision});
  }
  static Future<Map<String, dynamic>> checkLocalModelUpdate(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('checkLocalModelUpdate', {'path': path}) ?? const {});
  static Future<Map<String, dynamic>> hfDownload(String repo, String file) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'hfDownload', {'repo': repo, 'file': file}) ??
          const {});
  /// [revision] = commit Hugging Face yang diunduh (file dan checksum dari commit yang sama); kosong = HEAD saat mulai.
  static Future<Map<String, dynamic>> hfStartDownload(String repo, String file, {String revision = ''}) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'hfStartDownload', {'repo': repo, 'file': file, 'revision': revision}) ??
          const {});
  static Future<Map<String, dynamic>> hfStartModelDownload(String repo, List<String> files, {String revision = ''}) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'hfStartModelDownload', {'repo': repo, 'files': files, 'revision': revision}) ??
          const {});
  static Future<Map<String, dynamic>> hfDownloadState(String id) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'hfDownloadState', {'id': id}) ??
          const {});
  static Future<List<Map<String, dynamic>>> hfDownloadHistory() async =>
      (await _project.invokeListMethod<dynamic>('hfDownloadHistory') ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  static Future<Map<String, dynamic>> hfPauseDownload(String id) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'hfPauseDownload', {'id': id}) ??
          const {});
  static Future<Map<String, dynamic>> hfResumeDownload(String id) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'hfResumeDownload', {'id': id}) ??
          const {});
  static Future<void> hfCancelDownload(String id) async {
    await _project.invokeMethod<dynamic>('hfCancelDownload', {'id': id});
  }
  static Future<Map<String, dynamic>> copilotSuggest(String complaint, String sample, String focus) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('copilotSuggest', {
        'complaint': complaint, 'sample': sample, 'focus': focus,
      }) ?? const {});
  static Future<void> copilotApply(String path, String oldText, String newText) async {
    await _project.invokeMethod<dynamic>('copilotApply', {'path': path, 'oldText': oldText, 'newText': newText});
  }

  // ---- LoRA: lihat android/.../LoraBridge.kt
  static Future<Map<String, dynamic>> loraState() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('loraState') ?? const {});
  /// {adapters: [...], notes: [...]}; tiap adapter memuat valid/compatible/problems/warnings terhadap model aktif.
  static Future<Map<String, dynamic>> loraList() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('loraList') ?? const {});
  static Future<Map<String, dynamic>> loraImport(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('loraImport', {'path': path}) ?? const {});
  /// Memasang adapter. `hot: true` = langsung aktif di model yang sedang dimuat; false = aktif saat model dimuat.
  static Future<Map<String, dynamic>> loraAttach(String path, double scale) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('loraAttach', {'path': path, 'scale': scale}) ?? const {});
  static Future<Map<String, dynamic>> loraDetach() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('loraDetach') ?? const {});
  static Future<Map<String, dynamic>> loraSetScale(double scale) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('loraSetScale', {'scale': scale}) ?? const {});
  static Future<Map<String, dynamic>> loraDelete(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('loraDelete', {'path': path}) ?? const {});
  /// Prompt yang sama dijalankan tanpa dan dengan adapter (greedy). Hasil: {base, adapter: {text, tokens, ms, tps}, same, ...}.
  static Future<Map<String, dynamic>> loraAbTest(String prompt, {int maxTokens = 128}) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('loraAbTest', {'prompt': prompt, 'maxTokens': maxTokens}) ?? const {});

  static Future<Map<String, dynamic>> trainingLoadConfig() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('trainingLoadConfig') ?? const {});
  static Future<Map<String, dynamic>> trainingSaveConfig(Map<String, dynamic> config) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('trainingSaveConfig', {'config': jsonEncode(config)}) ?? const {});
  static Future<Map<String, dynamic>> runModelOperation(Map<String, dynamic> config) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('runModelOperation', {'config': jsonEncode(config)}) ?? const {});
  /// Gabung beberapa model bobot penuh di server -> GGUF -> (opsional) kuantisasi -> unduh ke HP.
  /// [config]: {name, sources: [..], weights: [..], quant}. Hasil: {outputPath, serverOutput, logs}.
  static Future<Map<String, dynamic>> runModelPipeline(Map<String, dynamic> config) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('runModelPipeline', {'config': jsonEncode(config)}) ?? const {});
  static Future<Map<String, dynamic>> trainingInspectDataset(String path, String method) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('trainingInspectDataset', {'path': path, 'method': method}) ?? const {});
  static Future<Map<String, dynamic>> trainingStart() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('trainingStart') ?? const {});
  static Future<Map<String, dynamic>> trainingReconnect(String id) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('trainingReconnect', {'id': id}) ?? const {});
  static Future<Map<String, dynamic>> trainingState() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('trainingState') ?? const {});
  static Future<void> trainingCancel(String id) async {
    await _project.invokeMethod<dynamic>('trainingCancel', {'id': id});
  }
  static Future<Map<String, dynamic>> trainingDownloadAdapter(String id, {required bool gguf}) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('trainingDownloadAdapter', {'id': id, 'gguf': gguf}) ?? const {});

  static Future<Map<String, dynamic>> checkForUpdate() async =>
      Map<String, dynamic>.from(await _update.invokeMapMethod<String, dynamic>(
              'checkForUpdate') ??
          const {});
  static Future<Map<String, dynamic>> downloadAndInstallUpdate(String url) async =>
      Map<String, dynamic>.from(await _update.invokeMapMethod<String, dynamic>(
              'downloadAndInstallUpdate', {'url': url}) ??
          const {});

  static Future<Map<String, String>> loadDrafts() async {
    final m = await _project.invokeMapMethod<String, dynamic>('loadDrafts');
    return (m ?? const {}).map((key, value) => MapEntry(key, value.toString()));
  }

  static Future<void> saveDraft(String path, String text) async {
    await _project
        .invokeMethod<dynamic>('saveDraft', {'path': path, 'text': text});
  }

  /// Stream hasil generate dari model lokal. Event berupa `String` (potongan token) atau `Map`
  /// `{type: 'notice', text: ...}` (peringatan non-fatal). Error membawa kode `ENGINE_*` (lihat errors.dart).
  /// Membatalkan langganan = menghentikan generate native di sisi Kotlin.
  static Stream<dynamic> chat(List<Map<String, String>> messages) =>
      _chat.receiveBroadcastStream({'messages': messages});
}
