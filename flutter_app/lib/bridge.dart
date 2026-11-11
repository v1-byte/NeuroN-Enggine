import 'dart:convert';
import 'package:flutter/services.dart';

/// Jembatan ke engine Kotlin:
///  - neuron/project  -> android/app/src/main/kotlin/com/neuron/engine/ProjectBridge.kt
///  - neuron/chat     -> android/app/src/main/kotlin/com/neuron/engine/NeuronBridge.kt
const _project = MethodChannel('neuron/project');
const _chat = EventChannel('neuron/chat');
const _update = MethodChannel('neuron/update');

class EngineSettings {
  const EngineSettings({this.baseUrl = '', this.model = '', this.apiKey = '', this.mode = 'API', this.modelPath = '', this.nativeAvailable = false});
  final String baseUrl;
  final String model;
  final String apiKey;
  final String mode;
  final String modelPath;
  final bool nativeAvailable;
}

class FeatureState {
  const FeatureState(
      {this.tools = false, this.words = const [], this.regex = const []});
  final bool tools;
  final List<String> words;
  final List<String> regex;
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
  static Future<void> write(String path, String text) async {
    await _project.invokeMethod<dynamic>('write', {'path': path, 'text': text});
  }

  static Future<EngineSettings> loadEngine() async {
    final m = await _project.invokeMapMethod<String, dynamic>('loadEngine');
    return EngineSettings(
      baseUrl: m?['baseUrl'] as String? ?? '',
      model: m?['model'] as String? ?? '',
      apiKey: m?['apiKey'] as String? ?? '',
      mode: m?['mode'] as String? ?? 'API',
      modelPath: m?['modelPath'] as String? ?? '',
      nativeAvailable: m?['nativeAvailable'] == true,
    );
  }

  static Future<void> saveEngine(EngineSettings s) async {
    await _project.invokeMethod<dynamic>('saveEngine', {
      'baseUrl': s.baseUrl,
      'model': s.model,
      'apiKey': s.apiKey,
    });
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

  static Future<Map<String, dynamic>> setEngineMode(String mode) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'setEngineMode', {'mode': mode}) ??
          const {});
  static Future<Map<String, dynamic>> setLocalModel(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'setLocalModel', {'path': path}) ??
          const {});
  static Future<List<Map<String, dynamic>>> localModels() async =>
      (await _project.invokeListMethod<dynamic>('localModels') ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  static Future<void> deleteLocalModel(String path) async {
    await _project.invokeMethod<dynamic>('deleteLocalModel', {'path': path});
  }
  static Future<Map<String, dynamic>> deviceHealth({int modelSize = 0}) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'deviceHealth', {'modelSize': modelSize}) ??
          const {});
  static Future<Map<String, dynamic>> activateLocalModel(String path) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'activateLocalModel', {'path': path}) ??
          const {});
  static Future<Map<String, dynamic>> serverState() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'serverState') ??
          const {});
  static Future<void> saveServer(int port, String apiKey) async {
    await _project.invokeMethod<dynamic>(
        'saveServer', {'port': port, 'apiKey': apiKey});
  }
  static Future<String> generateServerKey() async =>
      (await _project.invokeMethod<String>('generateServerKey')) ?? '';
  static Future<void> startServer() async {
    await _project.invokeMethod<dynamic>('startServer');
  }
  static Future<void> stopServer() async {
    await _project.invokeMethod<dynamic>('stopServer');
  }
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
  static Future<List<Map<String, dynamic>>> hfSearch(String query) async =>
      (await _project.invokeListMethod<dynamic>('hfSearch', {'query': query}) ??
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
  static Future<Map<String, dynamic>> hfDownload(String repo, String file) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'hfDownload', {'repo': repo, 'file': file}) ??
          const {});
  static Future<Map<String, dynamic>> hfStartDownload(String repo, String file) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'hfStartDownload', {'repo': repo, 'file': file}) ??
          const {});
  static Future<Map<String, dynamic>> hfDownloadState(String id) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>(
              'hfDownloadState', {'id': id}) ??
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

  static Future<Map<String, dynamic>> trainingLoadConfig() async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('trainingLoadConfig') ?? const {});
  static Future<Map<String, dynamic>> trainingSaveConfig(Map<String, dynamic> config) async =>
      Map<String, dynamic>.from(await _project.invokeMapMethod<String, dynamic>('trainingSaveConfig', {'config': jsonEncode(config)}) ?? const {});
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

  /// Stream token. Membatalkan langganan = membatalkan permintaan HTTP di sisi Kotlin.
  static Stream<dynamic> chat(List<Map<String, String>> messages) =>
      _chat.receiveBroadcastStream({'messages': messages});
}
