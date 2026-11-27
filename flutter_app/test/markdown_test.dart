import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/markdown_text.dart';

void main() {
  test('memisahkan teks dan blok kode', () {
    final b = parseBlocks('Halo\n```dart\nprint(1);\n```\nSelesai');
    expect(b.length, 3);
    expect(b[0].isCode, false);
    expect(b[1].isCode, true);
    expect(b[1].lang, 'dart');
    expect(b[1].text, 'print(1);');
    expect(b[2].text, 'Selesai');
  });

  test('blok kode yang belum ditutup (streaming) tetap kode', () {
    final b = parseBlocks('Ini:\n```\nline1\nline2');
    expect(b.last.isCode, true);
    expect(b.last.text, 'line1\nline2');
  });

  test('teks tanpa format menjadi satu blok', () {
    expect(parseBlocks('  \n').length, 0);
    expect(parseBlocks('a\n\nb').single.text, 'a\n\nb');
  });

  test('span inline: tebal, kode, dan judul', () {
    const base = TextStyle(fontSize: 12);
    final spans = inlineSpans('a **b** `c` d', base).cast<TextSpan>();
    expect(spans.map((s) => s.text).toList(), ['a ', 'b', ' ', 'c', ' d']);
    expect(spans[1].style!.fontWeight, FontWeight.w700);
    final h = inlineSpans('## Judul', base).cast<TextSpan>();
    expect(h.single.text, 'Judul');
  });
}
