import 'dart:convert';

import 'package:flutter/material.dart';

import 'syntax_highlight.dart';
import 'theme.dart';

class Problem {
  const Problem(this.line, this.column, this.error, this.message);
  final int line; // 1-based
  final int column; // 1-based
  final bool error; // false = peringatan
  final String message;
}

/// (baris, kolom) 1-based dari offset karakter.
(int, int) lineCol(String text, int offset) {
  final o = offset.clamp(0, text.length);
  var line = 1;
  var last = -1;
  for (var i = 0; i < o; i++) {
    if (text.codeUnitAt(i) == 10) {
      line++;
      last = i;
    }
  }
  return (line, o - last);
}

/// Offset karakter dari (baris, kolom) 1-based.
int offsetOf(String text, int line, int column) {
  var l = 1;
  var i = 0;
  while (l < line && i < text.length) {
    if (text.codeUnitAt(i) == 10) l++;
    i++;
  }
  return (i + column - 1).clamp(0, text.length);
}

const _ranges = <String, (num, num)>{
  'temperature': (0, 2),
  'top_p': (0, 1),
  'top_k': (0, 200),
  'max_tokens': (1, 8192),
};

/// Validasi isi berkas. JSON: sintaks (dengan posisi) lalu, untuk params.json, tipe dan rentang nilai.
List<Problem> analyze(String? path, String text) {
  if (languageForPath(path) != SyntaxLanguage.json || (path ?? '').endsWith('.jsonl')) return const [];
  if (text.trim().isEmpty) return const [Problem(1, 1, false, 'Berkas kosong')];
  Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (e) {
    final (l, c) = lineCol(text, e.offset ?? 0);
    return [Problem(l, c, true, 'JSON tidak valid: ${e.message}')];
  }
  final out = <Problem>[];
  final map = json is Map ? json : null;
  if ((path ?? '').endsWith('params.json') && map != null) {
    void at(String key, bool err, String msg) {
      final i = text.indexOf('"$key"');
      final (l, c) = i < 0 ? (1, 1) : lineCol(text, i);
      out.add(Problem(l, c, err, msg));
    }

    _ranges.forEach((key, r) {
      final v = map[key];
      if (v == null) return;
      if (v is! num) {
        at(key, true, '$key harus berupa angka');
      } else if (v < r.$1 || v > r.$2) {
        at(key, false, '$key = $v di luar rentang ${r.$1}–${r.$2}');
      }
    });
    final seed = map['seed'];
    if (seed != null && seed is! int) at('seed', true, 'seed harus bilangan bulat');
  }
  return out;
}

/// Daftar masalah; satu ketukan memanggil [onJump] dengan baris dan kolomnya.
class ProblemsPanel extends StatelessWidget {
  const ProblemsPanel({super.key, required this.problems, required this.onJump, this.onClose});

  final List<Problem> problems;
  final void Function(Problem) onJump;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final errors = problems.where((p) => p.error).length;
    return Container(
      constraints: const BoxConstraints(maxHeight: 160),
      color: panel,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
          child: Row(children: [
            Text('MASALAH · $errors galat, ${problems.length - errors} peringatan',
                style: const TextStyle(color: muted, fontSize: 9, letterSpacing: 1.1)),
            const Spacer(),
            if (onClose != null) IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 16), onPressed: onClose),
          ]),
        ),
        Flexible(
          child: problems.isEmpty
              ? const Padding(padding: EdgeInsets.fromLTRB(12, 4, 12, 10), child: Text('Tidak ada masalah.', style: TextStyle(color: green, fontSize: 12)))
              : ListView(shrinkWrap: true, children: [
                  for (final p in problems)
                    InkWell(
                      onTap: () => onJump(p),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        child: Row(children: [
                          Icon(p.error ? Icons.error_outline : Icons.warning_amber_rounded, size: 15, color: p.error ? errorRed : amber),
                          const SizedBox(width: 8),
                          Expanded(child: Text(p.message, style: const TextStyle(fontSize: 12))),
                          Text('${p.line}:${p.column}', style: const TextStyle(color: muted, fontSize: 11, fontFamily: 'monospace')),
                        ]),
                      ),
                    ),
                ]),
        ),
      ]),
    );
  }
}
