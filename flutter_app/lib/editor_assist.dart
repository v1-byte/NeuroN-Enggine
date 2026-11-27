import 'syntax_highlight.dart';

/// Logika murni untuk dua alat editor: lipat blok dan autocomplete. Tanpa Flutter, bisa dites langsung.

// ---------- Lipat blok ----------

/// Blok kurung yang membentang beberapa baris. Nomor baris berbasis 0 dan inklusif.
class FoldRegion {
  const FoldRegion(this.startLine, this.endLine);
  final int startLine;
  final int endLine;

  @override
  bool operator ==(Object other) => other is FoldRegion && other.startLine == startLine && other.endLine == endLine;

  @override
  int get hashCode => Object.hash(startLine, endLine);

  @override
  String toString() => 'FoldRegion($startLine-$endLine)';
}

/// Blok `{}` dan `[]` yang lebih dari satu baris. Kurung di dalam string JSON diabaikan.
/// Hanya berlaku untuk JSON; bahasa lain tidak punya blok yang bisa dilipat dengan aman.
/// Satu baris yang membuka beberapa blok sekaligus hanya mendapat blok terluarnya.
List<FoldRegion> foldRegions(String text, SyntaxLanguage lang) {
  if (lang != SyntaxLanguage.json) return const [];
  final stack = <(int, String)>[]; // (baris pembuka, kurung)
  final byStart = <int, FoldRegion>{};
  var line = 0;
  var inString = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '\n') {
      line++;
      inString = false; // string JSON tidak boleh melewati baris; jangan sampai satu kutip hilang merusak sisanya
      continue;
    }
    if (inString) {
      if (c == '\\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{' || c == '[') {
      stack.add((line, c));
    } else if (c == '}' || c == ']') {
      if (stack.isEmpty) continue;
      final (start, open) = stack.removeLast();
      final matches = (open == '{' && c == '}') || (open == '[' && c == ']');
      if (!matches) {
        stack.clear(); // kurung tidak berpasangan: berhenti menebak agar tidak melipat bagian yang salah
        continue;
      }
      if (line > start) {
        final prev = byStart[start];
        if (prev == null || line > prev.endLine) byStart[start] = FoldRegion(start, line);
      }
    }
  }
  final out = byStart.values.toList()..sort((a, b) => a.startLine.compareTo(b.startLine));
  return out;
}

/// Satu baris yang tampil setelah lipatan diterapkan. [number] adalah nomor baris asli (berbasis 1).
class VisibleLine {
  const VisibleLine(this.number, this.text, {this.foldStart});
  final int number;
  final String text;

  /// Bila baris ini adalah awal blok terlipat: nomor baris (berbasis 0) awal blok itu.
  final int? foldStart;
}

/// Baris yang tampil bila blok di [folded] (nomor baris awal, berbasis 0) dilipat.
/// Blok di dalam blok yang sudah terlipat ikut tersembunyi.
List<VisibleLine> applyFolds(String text, Set<int> folded, List<FoldRegion> regions) {
  final lines = text.split('\n');
  final byStart = {for (final r in regions) r.startLine: r};
  final out = <VisibleLine>[];
  var i = 0;
  while (i < lines.length) {
    final r = folded.contains(i) ? byStart[i] : null;
    if (r == null || r.endLine >= lines.length) {
      out.add(VisibleLine(i + 1, lines[i]));
      i++;
      continue;
    }
    final tail = lines[r.endLine].trim();
    out.add(VisibleLine(i + 1, '${lines[i]} … $tail', foldStart: i));
    i = r.endLine + 1;
  }
  return out;
}

/// Setelah teks berubah, buang lipatan yang tidak lagi cocok dengan blok mana pun.
Set<int> pruneFolds(Set<int> folded, List<FoldRegion> regions) {
  final starts = {for (final r in regions) r.startLine};
  return folded.where(starts.contains).toSet();
}

// ---------- Autocomplete ----------

/// Kunci chat/params.json persis seperti field ChatParams di Kotlin (camelCase).
const _chatParamKeys = [
  'systemPrompt', 'temperature', 'topP', 'topK', 'minP', 'repeatPenalty', 'presencePenalty',
  'frequencyPenalty', 'maxTokens', 'seed', 'stopSequences', 'contextLength',
];
const _modelfileWords = ['FROM', 'PARAMETER', 'TEMPLATE', 'SYSTEM', 'ADAPTER', 'LICENSE', 'MESSAGE'];
const _jinjaWords = [
  'if', 'elif', 'else', 'endif', 'for', 'endfor', 'set', 'in', 'messages', 'message.role',
  'message.content', 'add_generation_prompt', 'bos_token', 'eos_token', 'loop.last', 'loop.first',
];

/// Kosakata tetap per berkas. Hanya yang pasti dipakai: kunci ChatParams untuk
/// chat/params.json (sama dengan field ChatParams), kata kunci Modelfile, dan kata Jinja yang umum. Kunci berkas lain diambil
/// dari isi berkas itu sendiri lewat [suggest].
List<String> knownWords(String? path, SyntaxLanguage lang) {
  if (path == 'chat/params.json') return _chatParamKeys;
  return switch (lang) {
    SyntaxLanguage.modelfile => _modelfileWords,
    SyntaxLanguage.jinja => _jinjaWords,
    _ => const [],
  };
}

final _wordChar = RegExp(r'[A-Za-z0-9_.]');
final _wordRun = RegExp(r'[A-Za-z_][A-Za-z0-9_.]*');

/// Awalan kata tepat di kiri kursor, atau string kosong bila tidak ada.
String prefixAt(String text, int cursor) {
  if (cursor < 0 || cursor > text.length) return '';
  var s = cursor;
  while (s > 0 && _wordChar.hasMatch(text[s - 1])) {
    s--;
  }
  final p = text.substring(s, cursor);
  // Awalan harus dimulai huruf atau garis bawah; angka murni bukan kata.
  return p.isNotEmpty && RegExp(r'^[A-Za-z_]').hasMatch(p) ? p : '';
}

/// Usulan penyelesaian untuk kata di kiri kursor. Kosakata tetap diutamakan, lalu kata lain yang
/// sudah ada di berkas. Tidak mengusulkan kata yang sama persis dengan awalan, dan tidak
/// mengusulkan apa pun saat IME sedang menyusun teks (dikendalikan pemanggil).
List<String> suggest(String text, int cursor, SyntaxLanguage lang, {String? path, int max = 6}) {
  final prefix = prefixAt(text, cursor);
  if (prefix.isEmpty) return const [];
  final low = prefix.toLowerCase();
  final out = <String>[];
  final seen = <String>{prefix};

  void take(Iterable<String> words, int minPrefix) {
    if (prefix.length < minPrefix) return;
    for (final w in words) {
      if (out.length >= max) return;
      if (w.length > prefix.length && w.toLowerCase().startsWith(low) && seen.add(w)) out.add(w);
    }
  }

  take(knownWords(path, lang), 1);
  // Kata di berkas: tanpa kata yang sedang diketik (posisi kursor), supaya tidak mengusulkan dirinya sendiri.
  final start = cursor - prefix.length;
  final doc = <String>{};
  for (final m in _wordRun.allMatches(text)) {
    if (m.start == start) continue;
    doc.add(m.group(0)!);
  }
  take(doc, 2);
  return out;
}

class Completion {
  const Completion(this.text, this.cursor);
  final String text;
  final int cursor;
}

/// Ganti awalan kata di kiri kursor dengan [word]. Kursor berpindah ke akhir kata.
Completion applySuggestion(String text, int cursor, String word) {
  final prefix = prefixAt(text, cursor);
  final start = cursor - prefix.length;
  final next = text.replaceRange(start, cursor, word);
  return Completion(next, start + word.length);
}
