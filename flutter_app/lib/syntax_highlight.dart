import 'package:flutter/material.dart';

enum SyntaxLanguage { none, json, modelfile, jinja }

/// Pilih bahasa dari nama berkas project (mis. `chat/params.json`, `model/Modelfile`).
SyntaxLanguage languageForPath(String? path) {
  if (path == null) return SyntaxLanguage.none;
  final name = path.split('/').last.toLowerCase();
  if (name.endsWith('.json') || name.endsWith('.jsonl')) return SyntaxLanguage.json;
  if (name == 'modelfile' || name.endsWith('.modelfile')) return SyntaxLanguage.modelfile;
  if (name.endsWith('.jinja') || name.endsWith('.j2')) return SyntaxLanguage.jinja;
  return SyntaxLanguage.none;
}

const _kKey = Color(0xFF8CC8FF);
const _kString = Color(0xFFA8E6A1);
const _kNumber = Color(0xFFFFB86C);
const _kKeyword = Color(0xFFC792EA);
const _kComment = Color(0xFF68718A);
const _kPunct = Color(0xFF9AA6C8);

final _jsonToken = RegExp(r'"(?:[^"\\\n]|\\.)*"?|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\btrue\b|\bfalse\b|\bnull\b|[{}\[\],:]');
final _modelfileLine = RegExp(r'^(\s*)(FROM|PARAMETER|TEMPLATE|SYSTEM|ADAPTER|LICENSE|MESSAGE)\b', caseSensitive: false);
final _jinjaToken = RegExp(r'\{#[\s\S]*?#\}|\{\{[\s\S]*?\}\}|\{%[\s\S]*?%\}');

/// Pecah [text] menjadi span berwarna. Gabungan teks semua span SELALU sama dengan [text];
/// kalau tidak, posisi kursor di TextField bergeser.
List<TextSpan> highlight(String text, SyntaxLanguage lang, TextStyle? base) {
  switch (lang) {
    case SyntaxLanguage.json:
      return _scan(text, _jsonToken, base, (m, t) {
        final s = m.group(0)!;
        if (s.startsWith('"')) {
          var i = m.end;
          while (i < t.length && (t[i] == ' ' || t[i] == '\t')) {
            i++;
          }
          return i < t.length && t[i] == ':' ? _kKey : _kString;
        }
        if (s.length == 1 && '{}[],:'.contains(s)) return _kPunct;
        if (s == 'true' || s == 'false' || s == 'null') return _kKeyword;
        return _kNumber;
      });
    case SyntaxLanguage.jinja:
      return _scan(text, _jinjaToken, base, (m, _) {
        final s = m.group(0)!;
        if (s.startsWith('{#')) return _kComment;
        if (s.startsWith('{%')) return _kKeyword;
        return _kKey;
      });
    case SyntaxLanguage.modelfile:
      final out = <TextSpan>[];
      final lines = text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = i < lines.length - 1 ? '${lines[i]}\n' : lines[i];
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('#')) {
          out.add(TextSpan(text: line, style: base?.copyWith(color: _kComment)));
          continue;
        }
        final m = _modelfileLine.firstMatch(line);
        if (m == null) {
          out.add(TextSpan(text: line, style: base));
        } else {
          out.add(TextSpan(text: m.group(1), style: base));
          out.add(TextSpan(text: m.group(2), style: base?.copyWith(color: _kKeyword, fontWeight: FontWeight.w600)));
          out.add(TextSpan(text: line.substring(m.end), style: base));
        }
      }
      return out;
    case SyntaxLanguage.none:
      return [TextSpan(text: text, style: base)];
  }
}

List<TextSpan> _scan(String text, RegExp re, TextStyle? base, Color Function(RegExpMatch, String) colorOf) {
  final spans = <TextSpan>[];
  var last = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start), style: base));
    spans.add(TextSpan(text: m.group(0), style: base?.copyWith(color: colorOf(m, text)) ?? TextStyle(color: colorOf(m, text))));
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last), style: base));
  return spans;
}

/// TextEditingController yang mewarnai teks. Berkas besar (> [maxChars]) dan saat IME sedang
/// menyusun teks tidak diwarnai, supaya editor tetap ringan dan stabil.
class SyntaxController extends TextEditingController {
  SyntaxController({super.text});

  static const maxChars = 60000;
  SyntaxLanguage _language = SyntaxLanguage.none;

  SyntaxLanguage get language => _language;
  set language(SyntaxLanguage v) {
    if (v == _language) return;
    _language = v;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final composing = value.composing.isValid && !value.composing.isCollapsed;
    if (_language == SyntaxLanguage.none || text.length > maxChars || composing) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    return TextSpan(style: style, children: highlight(text, _language, style));
  }
}
