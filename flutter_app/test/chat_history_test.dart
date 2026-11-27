import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neuron/project');
  final calls = <MethodCall>[];
  final stored = <String, dynamic>{};

  setUp(() {
    calls.clear();
    stored.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'loadChatHistory':
          return {
            'lines': [
              {'role': 'user', 'text': 'Halo'},
              {'role': 'assistant', 'text': 'Hai'},
            ],
            'conversation': [
              {'role': 'user', 'content': 'Halo'},
              {'role': 'assistant', 'content': 'Hai'},
            ],
          };
        case 'saveChatHistory':
          stored.addAll(Map<String, dynamic>.from(call.arguments as Map));
          return {'ok': true};
        case 'clearChatHistory':
          stored.clear();
          return {'ok': true};
        case 'loadDrafts':
          return stored['drafts'] ?? <String, String>{};
        case 'saveDraft':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final drafts =
              Map<String, String>.from(stored['drafts'] as Map? ?? {});
          drafts[args['path'] as String] = args['text'] as String;
          stored['drafts'] = drafts;
          return {'ok': true};
        default:
          throw MissingPluginException('Unexpected method ${call.method}');
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('loads visible lines and API conversation separately', () async {
    final history = await Bridge.loadChatHistory();
    expect(history.lines, [
      {'role': 'user', 'text': 'Halo'},
      {'role': 'assistant', 'text': 'Hai'},
    ]);
    expect(history.conversation, [
      {'role': 'user', 'content': 'Halo'},
      {'role': 'assistant', 'content': 'Hai'},
    ]);
  });

  test('saves both chat views through one bridge call', () async {
    await Bridge.saveChatHistory(const ChatHistory(
      lines: [
        {'role': 'user', 'text': 'Tes'},
        {'role': 'assistant', 'text': 'Berhasil'},
      ],
      conversation: [
        {'role': 'user', 'content': 'Tes'},
        {'role': 'assistant', 'content': 'Berhasil'},
      ],
    ));
    expect(calls.single.method, 'saveChatHistory');
    expect((stored['lines'] as List).length, 2);
    expect((stored['conversation'] as List).length, 2);
  });

  test('clears persisted chat history', () async {
    await Bridge.clearChatHistory();
    expect(calls.single.method, 'clearChatHistory');
  });

  test('saves and restores an unsaved editor draft', () async {
    await Bridge.saveDraft('chat/params.json', '{"temperature":0.3}');
    expect(
        (await Bridge.loadDrafts())['chat/params.json'], '{"temperature":0.3}');
    expect(calls.map((call) => call.method), ['saveDraft', 'loadDrafts']);
  });
}
