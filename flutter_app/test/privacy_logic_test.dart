import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/privacy_logic.dart';

void main() {
  test('skema terdokumentasi dibaca sebagai kata dan regex', () {
    final p = previewPrivacy('{"version":1,"blocked_terms":["rahasia","sandi"],"regex":["\\\\d{16}"]}');
    expect(p.ok, isTrue);
    expect(p.words, ['rahasia', 'sandi']);
    expect(p.regex, [r'\d{16}']);
    expect(p.summary, '2 kata, 1 regex, 0 dilewati');
  });

  test('regex tidak valid ditandai dan dihitung dilewati', () {
    final p = previewPrivacy('{"regex":["(abc","ok.*"]}');
    expect(p.invalidRegex, ['(abc']);
    expect(p.regex, ['ok.*']);
    expect(p.summary, '0 kata, 1 regex, 1 dilewati');
    expect(p.warnings.any((w) => w.contains('tidak valid')), isTrue);
  });

  test('kunci dokumentasi diabaikan dan JSON rusak memberi galat', () {
    final p = previewPrivacy('{"blocked_terms":["a"],"description":["jangan ikut"]}');
    expect(p.words, ['a']);
    expect(previewPrivacy('{bukan json').ok, isFalse);
    expect(previewPrivacy('  ').ok, isFalse);
  });

  test('uji kalimat mencocokkan kata dan regex', () {
    final p = previewPrivacy('{"blocked_terms":["Rahasia"],"regex":["\\\\d{4}"]}');
    final hits = testPrivacy('ini rahasia 1234', p);
    expect(hits.map((h) => h.kind), ['kata', 'regex']);
    expect(testPrivacy('aman', p), isEmpty);
  });

  test('buildPrivacyJson bisa dibaca balik; bentuk dokumentasi dikenali', () {
    final t = buildPrivacyJson(['x'], ['y+']);
    final p = previewPrivacy(t);
    expect(p.words, ['x']);
    expect(p.regex, ['y+']);
    expect(isDocumentedShape(t), isTrue);
    expect(isDocumentedShape('{"forbidden_words":["x"]}'), isFalse);
  });
}
