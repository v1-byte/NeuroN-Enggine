import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/problems_panel.dart';
import 'package:neuron_engine/syntax_highlight.dart';

void main() {
  test('bahasa dipilih dari nama berkas', () {
    expect(languageForPath('chat/params.json'), SyntaxLanguage.json);
    expect(languageForPath('model/Modelfile'), SyntaxLanguage.modelfile);
    expect(languageForPath('x/template.jinja'), SyntaxLanguage.jinja);
    expect(languageForPath('knowledge/a.md'), SyntaxLanguage.none);
  });

  test('highlight tidak mengubah teks (kursor tidak boleh bergeser)', () {
    const samples = {
      SyntaxLanguage.json: '{\n  "temperature": 0.7,\n  "stop": ["a", "b\\"c"],\n  "ok": true, "x": null\n}\n',
      SyntaxLanguage.modelfile: '# komentar\nFROM model.gguf\nPARAMETER temperature 0.7\n\nSYSTEM "halo"',
      SyntaxLanguage.jinja: '{% for m in messages %}{{ m.content }}{# c #}{% endfor %}',
    };
    samples.forEach((lang, text) {
      final spans = highlight(text, lang, const TextStyle());
      expect(spans.map((s) => s.text).join(), text, reason: '$lang');
    });
  });

  test('kunci dan nilai JSON diberi warna berbeda', () {
    final spans = highlight('{"a": "b"}', SyntaxLanguage.json, const TextStyle());
    final key = spans.firstWhere((s) => s.text == '"a"');
    final val = spans.firstWhere((s) => s.text == '"b"');
    expect(key.style?.color, isNot(val.style?.color));
  });

  test('lineCol dan offsetOf saling berbalik', () {
    const t = 'ab\ncde\nf';
    expect(lineCol(t, 0), (1, 1));
    expect(lineCol(t, 4), (2, 2));
    expect(offsetOf(t, 2, 2), 4);
    expect(offsetOf(t, 3, 1), 7);
  });

  test('analyze: JSON rusak memberi galat berposisi', () {
    final p = analyze('chat/params.json', '{\n  "a": 1,\n  "b": \n}');
    expect(p, isNotEmpty);
    expect(p.first.error, isTrue);
    expect(p.first.line, greaterThanOrEqualTo(2));
  });

  test('analyze: params.json di luar rentang jadi peringatan', () {
    final p = analyze('chat/params.json', '{\n  "temperature": 3.5,\n  "top_p": 0.9,\n  "seed": 1.5\n}');
    expect(p.where((x) => !x.error && x.message.contains('temperature')).length, 1);
    expect(p.where((x) => x.error && x.message.contains('seed')).length, 1);
    expect(p.any((x) => x.message.contains('top_p')), isFalse);
    expect(analyze('knowledge/a.md', 'bukan json'), isEmpty);
  });
}
