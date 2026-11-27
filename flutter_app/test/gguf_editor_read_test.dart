import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/gguf_editor.dart';
import 'package:neuron_engine/theme.dart';

/// Alur baca total di Editor GGUF: ringkasan model, pemeriksaan integritas, tabel tensor, dan isi array.
void main() {
  const channel = MethodChannel('neuron/project');
  const model = '/models/bytecode66__Froged_N1/qwen2.5-0.5b-instruct-q4_k_m.gguf';
  final calls = <MethodCall>[];
  var complete = true;

  setUp(() {
    calls.clear();
    complete = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'localModels':
          return [
            {'name': 'qwen2.5-0.5b-instruct-q4_k_m.gguf', 'path': model, 'size': 491400032, 'active': true},
          ];
        case 'ggufInspect':
          return {
            'path': model,
            'name': 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
            'size': 491400032,
            'version': 3,
            'tensorCount': 290,
            'tokenCount': 151387,
            'params': 494032768,
            'layers': 24,
            'fileTypeName': 'Q4_K_M',
            'dataBytes': 490000000,
            'byType': [
              {'type': 'Q4_K', 'count': 168, 'bytes': 300000000, 'params': 1},
              {'type': 'F32', 'count': 121, 'bytes': 1000000, 'params': 1},
            ],
            'issues': complete ? <String>[] : <String>['2 tensor melewati akhir berkas: berkas terpotong atau unduhan belum lengkap'],
            'complete': complete,
            'entries': [
              {'key': 'general.architecture', 'type': 'string', 'value': 'qwen2', 'editable': false, 'viewable': false, 'note': 'dilindungi'},
              {'key': 'tokenizer.ggml.tokens', 'type': 'array', 'elemType': 'string', 'count': 151387, 'value': null, 'editable': false, 'viewable': true, 'note': ''},
            ],
          };
        case 'ggufTensors':
          final q = (call.arguments as Map)['query'] as String;
          return {
            'total': 290,
            'matched': q.isEmpty ? 290 : 1,
            'offset': (call.arguments as Map)['offset'],
            'items': [
              {'name': q.isEmpty ? 'token_embd.weight' : 'blk.3.attn_q.weight', 'shape': [896, 151936], 'type': 'Q4_K', 'bytes': 76000000, 'params': 136134656, 'offset': 0},
            ],
          };
        case 'ggufArray':
          return {
            'key': 'tokenizer.ggml.tokens',
            'elemType': 'string',
            'count': 151387,
            'offset': (call.arguments as Map)['offset'],
            'items': ['!', '"', 'a\nb'],
          };
        default:
          throw MissingPluginException('Unexpected method ${call.method}');
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: neuronTheme(),
      home: Scaffold(body: SingleChildScrollView(child: GgufEditorPage(onLog: (_, __) {}, initialPath: model))),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('membuka model terpasang tanpa menghitung SHA-256 dan menampilkan ringkasan total', (tester) async {
    await pump(tester);
    expect((calls.firstWhere((c) => c.method == 'localModels').arguments as Map)['hash'], false);
    expect(find.textContaining('Arsitektur qwen2 · GGUF v3 · Q4_K_M · 494 juta parameter · 24 blok'), findsOneWidget);
    expect(find.textContaining('290 tensor'), findsWidgets);
    expect(find.textContaining('Terbaca utuh'), findsOneWidget);
    expect(find.textContaining('Q4_K  ·  168 tensor'), findsOneWidget);
  });

  testWidgets('model terpotong dilaporkan, bukan dianggap utuh', (tester) async {
    complete = false;
    await pump(tester);
    expect(find.text('Perlu perhatian:'), findsOneWidget);
    expect(find.textContaining('unduhan belum lengkap'), findsOneWidget);
    expect(find.textContaining('Terbaca utuh'), findsNothing);
  });

  testWidgets('tabel tensor dimuat saat dibuka dan bisa dicari', (tester) async {
    await pump(tester);
    expect(calls.where((c) => c.method == 'ggufTensors'), isEmpty);
    await tester.tap(find.text('Tensor (290)'));
    await tester.pumpAndSettle();
    expect(find.text('token_embd.weight'), findsOneWidget);
    expect(find.textContaining('Q4_K · [896 × 151936]'), findsOneWidget);

    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText?.startsWith('Cari nama tensor') == true), 'attn');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('blk.3.attn_q.weight'), findsOneWidget);
    expect((calls.lastWhere((c) => c.method == 'ggufTensors').arguments as Map)['query'], 'attn');
  });

  testWidgets('array token bisa dibuka dan dibaca per halaman', (tester) async {
    await pump(tester);
    await tester.tap(find.text('tokenizer.ggml.tokens'));
    await tester.pumpAndSettle();
    final call = calls.lastWhere((c) => c.method == 'ggufArray');
    expect((call.arguments as Map)['key'], 'tokenizer.ggml.tokens');
    expect((call.arguments as Map)['offset'], 0);
    expect(find.textContaining('1–3 dari 151.387'), findsOneWidget);
    expect(find.textContaining(r'a\nb'), findsOneWidget);
  });
}
