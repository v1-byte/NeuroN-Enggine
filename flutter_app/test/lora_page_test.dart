import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/bridge.dart';
import 'package:neuron_engine/lora_page.dart';
import 'package:neuron_engine/theme.dart';

/// FilledButton.icon membuat subkelas privat, jadi find.byType(FilledButton) tidak cukup: cocokkan lewat predikat.
Finder _filled(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is FilledButton));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neuron/project');
  final calls = <MethodCall>[];
  Map<String, dynamic> state = {};
  List<Map<String, dynamic>> adapters = [];

  Map<String, dynamic> adapter(String name, {bool ok = true, bool active = false, List<String> problems = const [], List<String> warnings = const []}) => {
        'name': name,
        'path': '/models/loras/$name',
        'size': 12000000,
        'active': active,
        'valid': true,
        'compatible': ok,
        'arch': 'llama',
        'alpha': 16.0,
        'problems': problems,
        'warnings': warnings,
      };

  setUp(() {
    calls.clear();
    state = {'modelName': 'base.gguf', 'modelArch': 'llama', 'loraPath': '', 'loraName': '', 'scale': 1.0, 'engineLoaded': false, 'engineLoraPath': ''};
    adapters = [adapter('good.gguf'), adapter('bad.gguf', ok: false, problems: ['Adapter ini untuk arsitektur qwen2'])];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'loraState':
          return state;
        case 'loraList':
          return {'adapters': adapters, 'notes': <String>[]};
        case 'loraAttach':
          final path = (call.arguments as Map)['path'] as String;
          state = {...state, 'loraPath': path, 'loraName': path.split('/').last};
          adapters = [adapter('good.gguf', active: true), adapters[1]];
          return {'ok': true, 'hot': false, 'warnings': <String>[]};
        case 'loraDetach':
          state = {...state, 'loraPath': '', 'loraName': ''};
          adapters = [adapter('good.gguf'), adapters[1]];
          return {'ok': true, 'hot': false};
        case 'loraAbTest':
          return {
            'base': {'text': 'jawaban dasar', 'tokens': 10, 'ms': 1000, 'tps': 10.0},
            'adapter': {'text': 'jawaban adapter', 'tokens': 12, 'ms': 1000, 'tps': 12.0},
            'adapterName': 'good.gguf',
            'scale': 1.0,
            'same': false,
          };
        default:
          throw MissingPluginException('Unexpected method ${call.method}');
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('bridge meneruskan argumen LoRA apa adanya', () async {
    await Bridge.loraAttach('/models/loras/good.gguf', 0.75);
    final args = Map<String, dynamic>.from(calls.single.arguments as Map);
    expect(calls.single.method, 'loraAttach');
    expect(args['path'], '/models/loras/good.gguf');
    expect(args['scale'], 0.75);

    await Bridge.loraAbTest('halo', maxTokens: 64);
    final ab = Map<String, dynamic>.from(calls.last.arguments as Map);
    expect(ab['prompt'], 'halo');
    expect(ab['maxTokens'], 64);
  });

  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(MaterialApp(
      theme: neuronTheme(),
      home: Scaffold(body: SingleChildScrollView(child: LoraPage(onLog: (_, __) {}))),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('adapter cocok bisa dipasang, yang tidak cocok dikunci dan menampilkan alasannya', (t) async {
    await pump(t);
    expect(find.text('good.gguf'), findsOneWidget);
    expect(find.text('Adapter ini untuk arsitektur qwen2'), findsOneWidget);
    // Hanya adapter yang cocok yang punya tombol Pasang aktif.
    final buttons = _filled('Pasang');
    expect(buttons, findsNWidgets(2));
    expect(t.widget<FilledButton>(buttons.at(0)).onPressed, isNotNull);
    expect(t.widget<FilledButton>(buttons.at(1)).onPressed, isNull);
  });

  testWidgets('memasang lalu melepas adapter memperbarui status', (t) async {
    await pump(t);
    expect(find.text('Tidak ada adapter'), findsOneWidget);

    await t.ensureVisible(_filled('Pasang').first);
    await t.tap(_filled('Pasang').first);
    await t.pumpAndSettle();
    expect(calls.any((c) => c.method == 'loraAttach'), isTrue);
    expect(find.text('Lepas adapter'), findsOneWidget);

    await t.ensureVisible(find.text('Lepas adapter'));
    await t.tap(find.text('Lepas adapter'));
    await t.pumpAndSettle();
    expect(calls.any((c) => c.method == 'loraDetach'), isTrue);
    expect(find.text('Tidak ada adapter'), findsOneWidget);
  });

  testWidgets('uji A/B menampilkan dua jawaban berdampingan', (t) async {
    state = {...state, 'loraPath': '/models/loras/good.gguf', 'loraName': 'good.gguf'};
    adapters = [adapter('good.gguf', active: true)];
    await pump(t);

    await t.enterText(find.byType(TextField), 'siapa kamu?');
    await t.ensureVisible(find.text('Jalankan uji A/B'));
    await t.tap(find.text('Jalankan uji A/B'));
    await t.pumpAndSettle();

    final sent = calls.firstWhere((c) => c.method == 'loraAbTest').arguments as Map;
    expect(sent['prompt'], 'siapa kamu?');
    expect(find.text('jawaban dasar'), findsOneWidget);
    expect(find.text('jawaban adapter'), findsOneWidget);
  });

  testWidgets('uji A/B dikunci sampai ada adapter terpasang', (t) async {
    await pump(t);
    await t.ensureVisible(find.text('Pasang adapter dulu'));
    expect(t.widget<FilledButton>(_filled('Pasang adapter dulu').first).onPressed, isNull);
  });
}
