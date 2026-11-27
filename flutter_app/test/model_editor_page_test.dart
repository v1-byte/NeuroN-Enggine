import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/model_editor_page.dart';
import 'package:neuron_engine/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neuron/project');
  late List<Map<String, dynamic>> models;

  setUp(() {
    models = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'localModels':
          return models;
        case 'ggufInspect':
          return {'path': '/m/a.gguf', 'name': 'a.gguf', 'size': 100000000, 'complete': true, 'issues': <String>[], 'fileTypeName': 'Q4_K_M', 'tensorCount': 10, 'tokenCount': 100};
        case 'deviceHealth':
          return {'totalRam': 8000000000, 'availableRam': 4000000000};
        case 'modelParamsGet':
          return {
            'name': 'a.gguf',
            'active': true,
            'overrides': {'temperature': 0.3},
            'base': {'temperature': 0.8, 'topP': 0.95, 'topK': 40, 'minP': 0.05, 'repeatPenalty': 1.1, 'maxTokens': 512, 'seed': -1, 'contextLength': 4096},
            'effective': {'temperature': 0.3},
          };
        case 'privacyLoad':
          return {'text': '', 'exists': false, 'source': 'x/y', 'file': 'a.privacy.json'};
        default:
          throw MissingPluginException('Unexpected ${call.method}');
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> pump(WidgetTester t, {VoidCallback? lib, VoidCallback? imp}) async {
    await t.pumpWidget(MaterialApp(
      theme: neuronTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ModelEditorPage(onLog: (_, __) {}, onOpenLibrary: lib, onOpenImport: imp),
        ),
      ),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('tanpa model: tampil tombol Library dan Impor yang berfungsi', (t) async {
    var lib = 0, imp = 0;
    await pump(t, lib: () => lib++, imp: () => imp++);
    expect(find.text('Belum ada model lokal'), findsOneWidget);
    await t.tap(find.text('Buka Library'));
    await t.tap(find.text('Impor GGUF'));
    expect(lib, 1);
    expect(imp, 1);
  });

  testWidgets('dengan model: tab Info menampilkan kuantisasi dan estimasi RAM', (t) async {
    models = [
      {'name': 'a.gguf', 'path': '/m/a.gguf', 'size': 100000000, 'active': true, 'ramRecommended': 125000000, 'sourceRepo': 'x/y', 'sourceRevision': 'abc'}
    ];
    await pump(t);
    expect(find.text('Q4_K_M'), findsOneWidget);
    expect(find.textContaining('Cukup'), findsOneWidget);
    expect(find.text('Privasi'), findsOneWidget);
    await t.tap(find.text('Privasi'));
    await t.pumpAndSettle();
    expect(find.textContaining('Pratinjau hasil baca'), findsOneWidget);
  });

  testWidgets('tab Tokenizer: model tanpa daftar token dilaporkan', (t) async {
    models = [
      {'name': 'a.gguf', 'path': '/m/a.gguf', 'size': 100000000, 'active': true, 'ramRecommended': 125000000}
    ];
    await pump(t);
    await t.tap(find.text('Tokenizer'));
    await t.pumpAndSettle();
    expect(find.textContaining('tidak punya daftar token'), findsOneWidget);
  });

  testWidgets('tab Parameter model: nilai tersimpan terisi dan petunjuk nilai proyek tampil', (t) async {
    models = [
      {'name': 'a.gguf', 'path': '/m/a.gguf', 'size': 100000000, 'active': true, 'ramRecommended': 125000000}
    ];
    await pump(t);
    await t.tap(find.text('Parameter model'));
    await t.pumpAndSettle();
    expect(find.textContaining('hanya berlaku untuk model ini'), findsOneWidget);
    expect(find.text('0.3'), findsOneWidget);
    expect(find.text('Jalankan uji'), findsOneWidget);
  });
}
