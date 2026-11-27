import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/tab_session.dart';

void main() {
  const valid = ['chat/params.json', 'model/Modelfile', 'engine/api.json', 'eval/cases.json'];

  test('bolak-balik menjaga urutan dan tab aktif', () {
    final raw = encodeTabSession(['model/Modelfile', 'chat/params.json'], 'model/Modelfile');
    final s = decodeTabSession(raw, valid);
    expect(s.open, ['model/Modelfile', 'chat/params.json']);
    expect(s.active, 'model/Modelfile');
  });

  test('engine/api.json tidak pernah disimpan atau dipulihkan', () {
    final raw = encodeTabSession(['engine/api.json', 'chat/params.json'], 'engine/api.json');
    expect(raw.contains('api.json'), false);
    final s = decodeTabSession('{"open":["engine/api.json","chat/params.json"],"active":"engine/api.json"}', valid);
    expect(s.open, ['chat/params.json']);
    expect(s.active, 'chat/params.json');
  });

  test('path yang sudah tidak ada dan duplikat dibuang', () {
    final s = decodeTabSession('{"open":["hilang.json","eval/cases.json","eval/cases.json"],"active":"hilang.json"}', valid);
    expect(s.open, ['eval/cases.json']);
    expect(s.active, 'eval/cases.json');
  });

  test('data rusak atau kosong menghasilkan sesi kosong tanpa melempar', () {
    for (final raw in [null, '', 'bukan json', '[1,2]', '{"open":"x"}', '{"open":[1,null]}']) {
      final s = decodeTabSession(raw, valid);
      expect(s.open, isEmpty, reason: '$raw');
      expect(s.active, isNull, reason: '$raw');
    }
  });
}
