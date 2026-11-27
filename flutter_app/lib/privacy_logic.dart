import 'dart:convert';

/// Pembacaan privacy.json sisi Flutter untuk PRATINJAU. Meniru aturan PrivacyPolicy.kt
/// (kunci diklasifikasi dari namanya). Hasil resmi tetap dari Kotlin saat Simpan; ini hanya
/// membantu pengguna melihat apa yang akan ditangkap sebelum menyimpan. Regex dicek dengan
/// RegExp Dart, jadi sebagian sintaks khusus Java bisa dinilai berbeda.
class PrivacyPreview {
  const PrivacyPreview({
    this.words = const [],
    this.regex = const [],
    this.invalidRegex = const [],
    this.skipped = 0,
    this.warnings = const [],
    this.error,
  });

  final List<String> words;
  final List<String> regex;
  final List<String> invalidRegex;
  final int skipped;
  final List<String> warnings;
  final String? error;

  bool get ok => error == null;

  /// Ringkasan satu baris, mis. "12 kata, 3 regex, 1 dilewati".
  String get summary => error != null
      ? error!
      : '${words.length} kata, ${regex.length} regex, ${skipped + invalidRegex.length} dilewati';
}

const _regexKeys = ['regex', 'pattern', 'pola'];
const _wordKeys = [
  'block', 'deny', 'forbid', 'terlarang', 'blokir', 'term', 'word', 'kata',
  'istilah', 'keyword', 'sensitive', 'redact', 'phrase',
];
const _itemWordKeys = {'term', 'word', 'kata', 'istilah', 'phrase', 'keyword', 'value', 'text'};
const _ignoredKeys = ['description', 'comment', 'example', 'note', 'metadata', 'schema', 'changelog'];
const _maxLen = 500;
const _maxBytes = 2000000;

bool _hasAny(String key, List<String> parts) => parts.any(key.contains);

bool isValidRegex(String pattern) {
  try {
    RegExp(pattern);
    return true;
  } catch (_) {
    return false;
  }
}

PrivacyPreview previewPrivacy(String text) {
  if (text.trim().isEmpty) return const PrivacyPreview(error: 'privacy.json kosong');
  if (text.length > _maxBytes) return const PrivacyPreview(error: 'privacy.json terlalu besar (maks 2000 KB)');
  Object? root;
  try {
    root = jsonDecode(text);
  } on FormatException catch (e) {
    return PrivacyPreview(error: 'Bukan JSON yang valid: ${e.message}');
  }
  final words = <String>{};
  final regex = <String>{};
  var skipped = 0;
  final ruleKeys = [..._regexKeys, ..._wordKeys, 'rule', 'aturan', 'entit', 'pii'];

  void classify(String raw, String key, bool ctx, bool inArray) {
    final v = raw.trim();
    if (v.isEmpty) return;
    final isRegexKey = _hasAny(key, _regexKeys);
    final isWord = (inArray && _hasAny(key, _wordKeys)) || (ctx && _itemWordKeys.contains(key));
    if (!isRegexKey && !isWord) return;
    if (v.length > _maxLen) {
      skipped++;
      return;
    }
    (isRegexKey ? regex : words).add(v);
  }

  void walk(Object? el, String key, bool ctx, bool inArray) {
    if (el is Map) {
      final here = ctx || _hasAny(key, ruleKeys);
      el.forEach((k, v) {
        final lk = '$k'.toLowerCase();
        if (!_hasAny(lk, _ignoredKeys)) walk(v, lk, here, false);
      });
    } else if (el is List) {
      final here = ctx || _hasAny(key, ruleKeys);
      for (final e in el) {
        walk(e, key, here, true);
      }
    } else if (el is String) {
      classify(el, key, ctx, inArray);
    }
  }

  walk(root, '', false, false);
  final valid = <String>[];
  final invalid = <String>[];
  for (final r in regex) {
    (isValidRegex(r) ? valid : invalid).add(r);
  }
  final warnings = <String>[];
  if (invalid.isNotEmpty) warnings.add('${invalid.length} pola regex tidak valid dan akan dilewati.');
  if (skipped > 0) warnings.add('$skipped entri dilewati karena lebih dari $_maxLen karakter.');
  if (words.isEmpty && valid.isEmpty) {
    warnings.add('Tidak ada kata atau regex yang dikenali. Pakai kunci seperti blocked_terms, forbidden_words, regex, atau patterns.');
  }
  return PrivacyPreview(
    words: words.toList(),
    regex: valid,
    invalidRegex: invalid,
    skipped: skipped,
    warnings: warnings,
  );
}

/// Tulis ulang ke skema yang terdokumentasi: {"version":1,"blocked_terms":[...],"regex":[...]}.
String buildPrivacyJson(List<String> words, List<String> regex) =>
    const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'blocked_terms': words,
      'regex': regex,
    });

/// Apakah [text] sudah memakai persis kunci terdokumentasi, sehingga daftar item bisa
/// ditulis balik tanpa membuang kunci lain.
bool isDocumentedShape(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! Map) return false;
    const allowed = {'version', 'blocked_terms', 'regex'};
    return j.keys.every((k) => allowed.contains(k));
  } catch (_) {
    return false;
  }
}

class PrivacyHit {
  const PrivacyHit(this.kind, this.rule, this.match);
  final String kind; // 'kata' | 'regex'
  final String rule;
  final String match;
}

/// Uji sebuah kalimat terhadap hasil baca. Kata dicocokkan tanpa membedakan huruf besar/kecil
/// (perkiraan; perilaku guardrail di chat tetap ditentukan engine).
List<PrivacyHit> testPrivacy(String sample, PrivacyPreview p) {
  final hits = <PrivacyHit>[];
  final lower = sample.toLowerCase();
  for (final w in p.words) {
    final i = lower.indexOf(w.toLowerCase());
    if (i >= 0) hits.add(PrivacyHit('kata', w, sample.substring(i, i + w.length)));
  }
  for (final r in p.regex) {
    try {
      final m = RegExp(r, caseSensitive: false).firstMatch(sample);
      if (m != null) hits.add(PrivacyHit('regex', r, m.group(0) ?? ''));
    } catch (_) {}
  }
  return hits;
}
