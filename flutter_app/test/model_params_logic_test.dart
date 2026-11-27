import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/model_params_logic.dart';

ParamField f(String k) => paramFields.firstWhere((x) => x.key == k);

void main() {
  test('kunci form sama dengan field ChatParams di Kotlin (camelCase)', () {
    expect(paramFields.map((x) => x.key).toList(),
        ['temperature', 'topP', 'topK', 'minP', 'repeatPenalty', 'maxTokens', 'seed', 'contextLength']);
  });

  test('kolom kosong valid dan tidak ikut dikirim', () {
    final r = readParamsForm({'temperature': '  ', 'topK': ''});
    expect(r.ok, true);
    expect(r.values, isEmpty);
    expect(r.json, '{}');
  });

  test('angka valid dibaca sebagai tipe yang benar, koma desimal diterima', () {
    final r = readParamsForm({'temperature': '0,7', 'topK': '40', 'seed': '-1', 'contextLength': '2048'});
    expect(r.ok, true);
    expect(r.values['temperature'], 0.7);
    expect(r.values['topK'], isA<int>());
    expect(jsonDecode(r.json), {'temperature': 0.7, 'topK': 40, 'seed': -1, 'contextLength': 2048});
  });

  test('rentang dan tipe divalidasi seperti di Kotlin', () {
    expect(validateParam(f('temperature'), '6'), isNotNull);
    expect(validateParam(f('temperature'), '5'), isNull);
    expect(validateParam(f('topP'), '1.5'), isNotNull);
    expect(validateParam(f('topK'), '1.5'), 'Harus bilangan bulat');
    expect(validateParam(f('topK'), '-1'), isNotNull);
    expect(validateParam(f('repeatPenalty'), '0'), isNotNull);
    expect(validateParam(f('repeatPenalty'), '0.01'), isNull);
    expect(validateParam(f('maxTokens'), '0'), isNotNull);
    expect(validateParam(f('contextLength'), '255'), isNotNull);
    expect(validateParam(f('contextLength'), '256'), isNull);
    expect(validateParam(f('temperature'), 'abc'), 'Harus berupa angka');
    expect(validateParam(f('temperature'), 'NaN'), isNotNull);
  });

  test('kesalahan dilaporkan per kunci dan form tidak ok', () {
    final r = readParamsForm({'temperature': '9', 'topP': '0.5'});
    expect(r.ok, false);
    expect(r.errors.keys, ['temperature']);
    expect(r.values['topP'], 0.5);
  });

  test('formTexts menampilkan angka bulat tanpa .0 dan mengabaikan kunci asing', () {
    final t = formTexts({'temperature': 0.3, 'topK': 20.0, 'maxTokens': 256, 'foo': 1});
    expect(t, {'temperature': '0.3', 'topK': '20', 'maxTokens': '256'});
  });

  test('contextWillChange', () {
    expect(contextWillChange({}, {}), false);
    expect(contextWillChange({'contextLength': 2048}, {'contextLength': 2048}), false);
    expect(contextWillChange({'contextLength': 2048}, {}), true);
    expect(contextWillChange({}, {'contextLength': 1024}), true);
  });
}
