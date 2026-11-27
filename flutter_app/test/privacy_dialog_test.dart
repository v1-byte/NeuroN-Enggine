import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/privacy_dialog.dart';
import 'package:neuron_engine/theme.dart';

/// Tes dialog "Edit privasi model" dengan channel `neuron/project` yang dipalsukan.
/// Skema privacy.json belum dikunci di sisi Kotlin, jadi dialog hanya boleh menyimpan teks apa adanya
/// dan menampilkan galat dari bridge; parsing diuji di PrivacyPolicyTest (Kotlin).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('neuron/project');
  final calls = <MethodCall>[];
  late List<Map<String, dynamic>> models;
  late Map<String, dynamic> loadReply;
  late Object? applyError;

  Map<String, dynamic> model(String name, {bool active = false}) => {
        'name': name,
        'path': '/models/$name',
        'size': 490000000,
        'active': active,
        'source': 'bytecode66/Froged_N1',
        'hasPrivacy': false,
        'file': '$name.privacy.json',
      };

  setUp(() {
    calls.clear();
    models = [model('a.gguf'), model('b.gguf', active: true)];
    loadReply = {'text': '', 'exists': false, 'source': 'bytecode66/Froged_N1', 'file': 'b.gguf.privacy.json'};
    applyError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'privacyModels':
          return models;
        case 'privacyLoad':
          return loadReply;
        case 'privacyFetch':
          return {'text': '{"blocked_terms":["rahasia"]}', 'source': 'bytecode66/Froged_N1'};
        case 'privacyApply':
          if (applyError != null) throw PlatformException(code: 'bad', message: applyError.toString());
          final use = (call.arguments as Map)['use'] == true;
          return {
            'used': use,
            'file': 'b.gguf.privacy.json',
            'words': ['rahasia'],
            'regex': <String>[],
            'warnings': <String>[],
          };
        default:
          throw MissingPluginException('Unexpected method ${call.method}');
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> open(WidgetTester t, List<String> logs) async {
    await t.pumpWidget(MaterialApp(
      theme: neuronTheme(),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showPrivacyDialog(ctx, (level, text) => logs.add('$level $text')),
              child: const Text('buka'),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('buka'));
    await t.pumpAndSettle();
  }

  Finder button(String label) => find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));

  testWidgets('tanpa model lokal, dialog menjelaskan apa yang harus dilakukan', (t) async {
    models = [];
    await open(t, []);
    expect(find.textContaining('Belum ada model lokal'), findsOneWidget);
    expect(calls.where((c) => c.method == 'privacyLoad'), isEmpty);
  });

  testWidgets('model aktif dipilih otomatis dan salinan lokalnya dimuat', (t) async {
    await open(t, []);
    final load = calls.firstWhere((c) => c.method == 'privacyLoad');
    expect((load.arguments as Map)['path'], '/models/b.gguf');
    expect(find.textContaining('Belum ada salinan'), findsOneWidget);
  });

  testWidgets('Ambil menandai perubahan belum disimpan; Simpan saja mengirim use=false', (t) async {
    final logs = <String>[];
    await open(t, logs);
    await t.tap(button('Ambil dari bytecode66/Froged_N1'));
    await t.pumpAndSettle();
    expect(find.text('● belum disimpan'), findsOneWidget);
    expect(find.textContaining('rahasia'), findsWidgets);

    await t.ensureVisible(button('Simpan saja'));
    await t.tap(button('Simpan saja'));
    await t.pumpAndSettle();
    final apply = calls.lastWhere((c) => c.method == 'privacyApply');
    expect((apply.arguments as Map)['use'], false);
    expect((apply.arguments as Map)['text'], '{"blocked_terms":["rahasia"]}');
    expect(find.text('● belum disimpan'), findsNothing);
    expect(find.textContaining('Belum dipakai di guardrail'), findsOneWidget);
  });

  testWidgets('Simpan & pakai hanya aktif untuk model aktif', (t) async {
    await open(t, []);
    await t.ensureVisible(button('Simpan & pakai'));
    expect(t.widget<ButtonStyleButton>(button('Simpan & pakai')).onPressed, isNotNull);

    models = [model('a.gguf'), model('b.gguf')]; // tidak ada yang aktif
    await t.tap(find.text('Tutup'));
    await t.pumpAndSettle();
    await t.tap(find.text('buka'));
    await t.pumpAndSettle();
    await t.ensureVisible(button('Simpan & pakai'));
    expect(t.widget<ButtonStyleButton>(button('Simpan & pakai')).onPressed, isNull);
    expect(find.textContaining('aktifkan model ini dulu'), findsOneWidget);
  });

  testWidgets('galat dari bridge (mis. JSON tidak valid) ditampilkan dan dicatat, bukan ditelan', (t) async {
    final logs = <String>[];
    applyError = 'privacy.json bukan JSON yang valid';
    await open(t, logs);
    await t.ensureVisible(button('Simpan saja'));
    await t.tap(button('Simpan saja'));
    await t.pumpAndSettle();
    expect(find.textContaining('Gagal: privacy.json bukan JSON yang valid'), findsOneWidget);
    expect(logs.any((l) => l.startsWith('ERROR')), isTrue);
  });
}
