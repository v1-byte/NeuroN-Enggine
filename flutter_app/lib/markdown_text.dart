import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Potongan pesan: teks biasa atau blok kode.
class MdBlock {
  const MdBlock(this.isCode, this.text, [this.lang = '']);
  final bool isCode;
  final String text;
  final String lang;
}

/// Pecah teks menjadi blok teks dan blok kode (```). Blok kode yang belum ditutup
/// (saat jawaban masih mengalir) tetap dianggap kode sampai akhir teks.
List<MdBlock> parseBlocks(String src) {
  final out = <MdBlock>[];
  final text = <String>[];
  final code = <String>[];
  var inCode = false;
  var lang = '';

  void flushText() {
    final t = text.join('\n').trim();
    if (t.isNotEmpty) out.add(MdBlock(false, t));
    text.clear();
  }

  for (final line in src.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```')) {
      if (inCode) {
        out.add(MdBlock(true, code.join('\n'), lang));
        code.clear();
        inCode = false;
      } else {
        flushText();
        lang = trimmed.substring(3).trim();
        inCode = true;
      }
    } else if (inCode) {
      code.add(line);
    } else {
      text.add(line);
    }
  }
  if (inCode) {
    out.add(MdBlock(true, code.join('\n'), lang));
  } else {
    flushText();
  }
  return out;
}

final _inline = RegExp(r'(\*\*[^*\n]+\*\*|`[^`\n]+`)');

/// Span inline untuk satu baris: **tebal** dan `kode`. Judul (#) ditampilkan tebal.
List<InlineSpan> inlineSpans(String line, TextStyle base) {
  final heading = RegExp(r'^\s{0,3}#{1,6}\s+(.*)$').firstMatch(line);
  if (heading != null) {
    return [TextSpan(text: heading.group(1), style: base.copyWith(fontWeight: FontWeight.w700, fontSize: (base.fontSize ?? 12) + 1))];
  }
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _inline.allMatches(line)) {
    if (m.start > last) spans.add(TextSpan(text: line.substring(last, m.start), style: base));
    final token = m.group(0)!;
    if (token.startsWith('**')) {
      spans.add(TextSpan(text: token.substring(2, token.length - 2), style: base.copyWith(fontWeight: FontWeight.w700)));
    } else {
      spans.add(TextSpan(
        text: token.substring(1, token.length - 1),
        style: base.copyWith(fontFamily: 'monospace', backgroundColor: const Color(0xFF12162A), fontSize: (base.fontSize ?? 12) - 0.5),
      ));
    }
    last = m.end;
  }
  if (last < line.length) spans.add(TextSpan(text: line.substring(last), style: base));
  return spans;
}

/// Tampilan pesan asisten: teks dengan format ringan dan blok kode dengan tombol Salin.
class RichMessage extends StatelessWidget {
  const RichMessage({super.key, required this.text, this.color = Colors.white});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: 12, height: 1.45, color: color);
    final children = <Widget>[];
    for (final b in parseBlocks(text)) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      if (b.isCode) {
        children.add(_CodeBlock(code: b.text, lang: b.lang));
      } else {
        final lines = b.text.split('\n');
        final spans = <InlineSpan>[];
        for (var i = 0; i < lines.length; i++) {
          spans.addAll(inlineSpans(lines[i], base));
          if (i < lines.length - 1) spans.add(TextSpan(text: '\n', style: base));
        }
        children.add(Text.rich(TextSpan(children: spans)));
      }
    }
    return SelectionArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children));
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, required this.lang});
  final String code;
  final String lang;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        decoration: BoxDecoration(color: const Color(0xFF12162A), borderRadius: BorderRadius.circular(9), border: Border.all(color: line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 2, 0),
            child: Row(children: [
              Expanded(child: Text(lang.isEmpty ? 'kode' : lang, style: const TextStyle(fontSize: 10, color: muted))),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(content: Text('Kode disalin'), duration: Duration(seconds: 1)));
                },
                icon: const Icon(Icons.copy_all_outlined, size: 13),
                label: const Text('Salin', style: TextStyle(fontSize: 10)),
                style: TextButton.styleFrom(foregroundColor: muted, minimumSize: const Size(0, 28), padding: const EdgeInsets.symmetric(horizontal: 8)),
              ),
            ]),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Text(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.4, color: Color(0xFFD7DEFF))),
          ),
        ]),
      );
}
