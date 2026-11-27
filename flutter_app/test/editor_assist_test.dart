import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/editor_assist.dart';
import 'package:neuron_engine/syntax_highlight.dart';

void main() {
  const json = '{\n  "a": {\n    "b": [\n      1,\n      2\n    ]\n  },\n  "s": "{ tidak dihitung }",\n  "c": 1\n}\n';

  group('lipat blok', () {
    test('mencari blok kurung multi-baris dan mengabaikan kurung dalam string', () {
      final r = foldRegions(json, SyntaxLanguage.json);
      expect(r, [const FoldRegion(0, 9), const FoldRegion(1, 6), const FoldRegion(2, 5)]);
    });

    test('bahasa selain JSON tidak punya lipatan', () {
      expect(foldRegions('{\n}', SyntaxLanguage.modelfile), isEmpty);
    });

    test('kurung tidak berpasangan tidak melempar dan tidak melipat sembarangan', () {
      expect(foldRegions('{\n  "a": [\n}\n', SyntaxLanguage.json), isEmpty);
      expect(foldRegions('}\n]\n', SyntaxLanguage.json), isEmpty);
    });

    test('blok satu baris tidak bisa dilipat', () {
      expect(foldRegions('{"a": [1, 2]}', SyntaxLanguage.json), isEmpty);
    });

    test('applyFolds menyembunyikan isi blok dan menjaga nomor baris asli', () {
      final regions = foldRegions(json, SyntaxLanguage.json);
      final v = applyFolds(json, {1}, regions);
      expect(v.map((l) => l.number).toList(), [1, 2, 8, 9, 10, 11]);
      expect(v[1].text, '  "a": { … },');
      expect(v[1].foldStart, 1);
    });

    test('lipatan di dalam lipatan lain ikut tersembunyi', () {
      final regions = foldRegions(json, SyntaxLanguage.json);
      final v = applyFolds(json, {1, 2}, regions);
      expect(v.map((l) => l.number).toList(), [1, 2, 8, 9, 10, 11]);
    });

    test('tanpa lipatan, semua baris tampil apa adanya', () {
      final v = applyFolds(json, {}, foldRegions(json, SyntaxLanguage.json));
      expect(v.map((l) => l.text).join('\n'), json);
    });

    test('pruneFolds membuang lipatan yang blok-nya sudah hilang', () {
      final regions = foldRegions(json, SyntaxLanguage.json);
      expect(pruneFolds({1, 4, 99}, regions), {1});
    });
  });

  group('autocomplete', () {
    test('prefixAt hanya menerima kata yang diawali huruf atau garis bawah', () {
      expect(prefixAt('foo tem', 7), 'tem');
      expect(prefixAt('x 12', 4), '');
      expect(prefixAt('', 0), '');
      expect(prefixAt('abc', 99), '');
    });

    test('kosakata tetap chat/params.json diutamakan', () {
      final s = suggest('{"te', 4, SyntaxLanguage.json, path: 'chat/params.json');
      expect(s.first, 'temperature');
    });

    test('mengambil kata dari isi berkas, bukan kata yang sedang diketik', () {
      const t = 'mutiara_biru\nmuti';
      final s = suggest(t, t.length, SyntaxLanguage.none);
      expect(s, ['mutiara_biru']);
    });

    test('kata yang sama persis dengan awalan tidak diusulkan', () {
      expect(suggest('PARAMETER PARAMETER', 19, SyntaxLanguage.modelfile), isEmpty);
    });

    test('chat/params.json memakai kunci camelCase persis seperti ChatParams', () {
      final s = suggest('{"to', 4, SyntaxLanguage.json, path: 'chat/params.json');
      expect(s, ['topP', 'topK']);
      expect(suggest('{"max', 5, SyntaxLanguage.json, path: 'chat/params.json'), ['maxTokens']);
    });

    test('Modelfile mengusulkan kata kunci', () {
      expect(suggest('PAR', 3, SyntaxLanguage.modelfile, path: 'model/Modelfile'), ['PARAMETER']);
    });

    test('applySuggestion mengganti awalan dan memindahkan kursor', () {
      final c = applySuggestion('{"te', 4, 'temperature');
      expect(c.text, '{"temperature');
      expect(c.cursor, 13);
    });
  });
}
