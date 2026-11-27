import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/theme.dart';
import 'package:neuron_engine/weight_ops_page.dart';

/// FilledButton.icon membuat subkelas privat, jadi find.byType(FilledButton) tidak cukup: cocokkan lewat predikat.
Finder _filled(String label) => find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is FilledButton));

bool _enabled(WidgetTester tester, String label) => tester.widget<FilledButton>(_filled(label)).onPressed != null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('helper murni', () {
    test('nama dan presisi tipe berkas', () {
      expect(ggufFileTypeName(15), 'Q4_K_M');
      expect(ggufFileTypeName(1), 'F16');
      expect(ggufFileTypeName(32), 'BF16');
      expect(ggufFileTypeName(999), 'tipe 999');
      expect(ggufFileTypeName(null), isNull);
      expect(isFullPrecisionFileType(0), isTrue);
      expect(isFullPrecisionFileType(1), isTrue);
      expect(isFullPrecisionFileType(32), isTrue);
      expect(isFullPrecisionFileType(15), isFalse);
      expect(isFullPrecisionFileType(null), isFalse);
    });

    test('file_type dibaca dari hasil inspeksi', () {
      expect(
        ggufFileTypeFromInspect({
          'entries': [
            {'key': 'general.architecture', 'value': 'llama'},
            {'key': 'general.file_type', 'value': '17'},
          ],
        }),
        17,
      );
      expect(ggufFileTypeFromInspect({'entries': [{'key': 'general.file_type', 'value': null}]}), isNull);
      expect(ggufFileTypeFromInspect({'entries': []}), isNull);
      expect(ggufFileTypeFromInspect(const {}), isNull);
    });

    test('safeOpName membersihkan nama untuk server', () {
      expect(safeOpName('Model Saya (v2).gguf'), 'Model_Saya__v2_');
      expect(safeOpName('../../etc/passwd'), 'etc_passwd');
      expect(safeOpName('   '), 'model');
      expect(safeOpName('', fallback: 'merged'), 'merged');
      expect(safeOpName('.hidden'), 'hidden');
      expect(safeOpName('a' * 100).length, 60);
    });

    test('parseMergeWeights menolak nilai tidak valid', () {
      expect(parseMergeWeights(['1', '0,5']), [1.0, 0.5]);
      expect(parseMergeWeights(['1', '0']), isNull);
      expect(parseMergeWeights(['1', '-1']), isNull);
      expect(parseMergeWeights(['1', 'abc']), isNull);
      expect(parseMergeWeights(['1', '']), isNull);
      expect(parseMergeWeights(['1', 'Infinity']), isNull);
      expect(parseMergeWeights(['1', 'NaN']), isNull);
    });
  });

  group('layar Ubah bobot', () {
    const channel = MethodChannel('neuron/project');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'localModels':
            return [
              {'name': 'm-Q5_K_M.gguf', 'path': '/models/m-Q5_K_M.gguf', 'size': 400000000},
            ];
          case 'loraList':
            return {'adapters': <Map<String, dynamic>>[], 'notes': <String>[]};
          case 'ggufInspect':
            return {
              'entries': [
                {'key': 'general.file_type', 'value': '17'},
              ],
            };
          case 'runModelOperation':
            return {'op': 'QUANTIZE', 'outputPath': '/models/m-edited-1.gguf', 'serverOutput': 'outputs/x.gguf', 'result': '', 'logs': <String>['selesai']};
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
        home: Scaffold(body: SingleChildScrollView(child: WeightOpsPage(onLog: (_, __) {}))),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('sumber terkuantisasi: kuantisasi baru perlu izin kuantisasi ulang', (tester) async {
      await pump(tester);
      expect(find.text('Tipe sumber: Q5_K_M'), findsOneWidget);
      expect(find.text('Izinkan kuantisasi ulang'), findsOneWidget);
      expect(_enabled(tester, 'Kuantisasi · simpan sebagai model baru'), isFalse);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(_enabled(tester, 'Kuantisasi · simpan sebagai model baru'), isTrue);
    });

    testWidgets('kuantisasi mengirim konfigurasi yang benar setelah konfirmasi', (tester) async {
      await pump(tester);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(_filled('Kuantisasi · simpan sebagai model baru'));
      await tester.pumpAndSettle();
      expect(find.text('Kuantisasi model?'), findsOneWidget);
      await tester.tap(find.text('Lanjutkan'));
      await tester.pumpAndSettle();

      final call = calls.singleWhere((c) => c.method == 'runModelOperation');
      final config = jsonDecode((call.arguments as Map)['config'] as String) as Map<String, dynamic>;
      expect(config['op'], 'QUANTIZE');
      expect(config['source'], '/models/m-Q5_K_M.gguf');
      expect(config['output'], 'outputs/m-Q5_K_M-Q4_K_M.gguf');
      expect(config['quantization'], 'Q4_K_M');
      expect(config['allowRequantize'], true);
      expect(find.textContaining('Model baru: m-edited-1.gguf'), findsOneWidget);
    });

    testWidgets('batal di dialog tidak memanggil server', (tester) async {
      await pump(tester);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(_filled('Kuantisasi · simpan sebagai model baru'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Batal'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'runModelOperation'), isEmpty);
    });

    testWidgets('gabung model menolak input yang salah tanpa memanggil server', (tester) async {
      await pump(tester);
      await tester.tap(_filled('Gabung · simpan sebagai model baru'));
      await tester.pumpAndSettle();
      expect(find.text('Isi semua baris model.'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Model 1'), 'Qwen/A');
      await tester.enterText(find.widgetWithText(TextField, 'Model 2'), 'model.gguf');
      await tester.tap(_filled('Gabung · simpan sebagai model baru'));
      await tester.pumpAndSettle();
      expect(find.textContaining('bukan file GGUF'), findsOneWidget);
      expect(calls.where((c) => c.method == 'runModelPipeline'), isEmpty);
    });

    testWidgets('tanam LoRA menjelaskan bila belum ada adapter', (tester) async {
      await pump(tester);
      expect(find.textContaining('Belum ada adapter'), findsOneWidget);
    });
  });
}
