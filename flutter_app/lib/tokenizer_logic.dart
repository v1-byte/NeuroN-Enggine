/// Logika murni tab Tokenizer: membaca key `tokenizer.*` dari hasil `ggufInspect` dan memeriksa
/// kewajarannya. Tanpa Flutter dan tanpa bridge, jadi bisa dites langsung.
class TokenizerInfo {
  const TokenizerInfo({
    required this.model,
    required this.pre,
    required this.tokenCount,
    required this.mergesCount,
    required this.bos,
    required this.eos,
    required this.unk,
    required this.pad,
    required this.sep,
    required this.addBos,
    required this.addEos,
    required this.hasChatTemplate,
    required this.hasTokenTypes,
  });

  final String? model;
  final String? pre;
  final int? tokenCount;
  final int? mergesCount;
  final int? bos;
  final int? eos;
  final int? unk;
  final int? pad;
  final int? sep;
  final bool? addBos;
  final bool? addEos;
  final bool hasChatTemplate;
  final bool hasTokenTypes;

  /// ID token khusus yang ada, urut tetap: (label, id).
  List<(String, int)> get specialIds => [
        if (bos != null) ('BOS', bos!),
        if (eos != null) ('EOS', eos!),
        if (unk != null) ('UNK', unk!),
        if (pad != null) ('PAD', pad!),
        if (sep != null) ('SEP', sep!),
      ];

  factory TokenizerInfo.fromEntries(List<Map<String, dynamic>> entries) {
    final byKey = <String, Map<String, dynamic>>{
      for (final e in entries) '${e['key']}': e,
    };
    String? str(String k) {
      final v = byKey[k]?['value'];
      if (v == null) return null;
      final s = '$v'.trim();
      return s.isEmpty ? null : s;
    }

    int? integer(String k) => int.tryParse(str(k) ?? '');
    bool? boolean(String k) {
      final s = str(k)?.toLowerCase();
      if (s == 'true' || s == '1') return true;
      if (s == 'false' || s == '0') return false;
      return null;
    }

    int? count(String k) => (byKey[k]?['count'] as num?)?.toInt();

    return TokenizerInfo(
      model: str('tokenizer.ggml.model'),
      pre: str('tokenizer.ggml.pre'),
      tokenCount: count('tokenizer.ggml.tokens'),
      mergesCount: count('tokenizer.ggml.merges'),
      bos: integer('tokenizer.ggml.bos_token_id'),
      eos: integer('tokenizer.ggml.eos_token_id'),
      unk: integer('tokenizer.ggml.unknown_token_id'),
      pad: integer('tokenizer.ggml.padding_token_id'),
      sep: integer('tokenizer.ggml.seperator_token_id') ?? integer('tokenizer.ggml.separator_token_id'),
      addBos: boolean('tokenizer.ggml.add_bos_token'),
      addEos: boolean('tokenizer.ggml.add_eos_token'),
      hasChatTemplate: str('tokenizer.chat_template') != null,
      hasTokenTypes: byKey.containsKey('tokenizer.ggml.token_type'),
    );
  }
}

/// Temuan pemeriksaan tokenizer. Hanya hal yang pasti salah atau mencurigakan; bukan opini gaya.
List<String> tokenizerIssues(TokenizerInfo t) {
  final out = <String>[];
  final n = t.tokenCount;
  if (n == null) {
    out.add('Berkas tidak punya daftar token (tokenizer.ggml.tokens). Model tidak bisa dipakai tanpa itu.');
    return out;
  }
  for (final (label, id) in t.specialIds) {
    if (id < 0 || id >= n) {
      out.add('ID $label ($id) di luar daftar token (0–${n - 1}).');
    }
  }
  if (t.eos == null) {
    out.add('EOS tidak diset: model bisa terus menghasilkan teks tanpa berhenti.');
  }
  final model = t.model?.toLowerCase();
  if (model == 'gpt2' && (t.mergesCount ?? 0) == 0) {
    out.add('Tokenizer BPE (gpt2) tanpa tokenizer.ggml.merges: tokenisasi akan salah.');
  }
  if (t.hasTokenTypes == false) {
    out.add('Tidak ada tokenizer.ggml.token_type: token khusus tidak bisa dikenali sebagai kontrol.');
  }
  if (t.addBos == true && t.bos == null) {
    out.add('add_bos_token aktif tetapi ID BOS tidak diset.');
  }
  if (t.bos != null && t.eos != null && t.bos == t.eos && t.addBos == true && t.addEos == true) {
    out.add('BOS dan EOS memakai ID yang sama sementara keduanya ditambahkan otomatis.');
  }
  return out;
}

/// Tampilan satu token yang aman dibaca: karakter kontrol dibuat terlihat, awalan SentencePiece
/// (U+2581) dan awalan byte-level (U+0120) ditandai dengan titik tengah.
String visibleToken(String raw) {
  if (raw.isEmpty) return '(kosong)';
  final b = StringBuffer();
  for (final r in raw.runes) {
    switch (r) {
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      case 0x2581:
      case 0x0120:
        b.write('·');
      default:
        if (r < 0x20 || r == 0x7F) {
          b.write('\\x${r.toRadixString(16).padLeft(2, '0')}');
        } else {
          b.writeCharCode(r);
        }
    }
  }
  return b.toString();
}

/// Indeks (dalam halaman) token yang cocok dengan [query], tanpa membedakan huruf besar/kecil.
/// Mencocokkan teks asli maupun tampilan; ID juga dicocokkan bila [query] berupa angka.
List<int> matchTokens(List<String> items, int offset, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return List<int>.generate(items.length, (i) => i);
  final id = int.tryParse(q);
  final out = <int>[];
  for (var i = 0; i < items.length; i++) {
    if (items[i].toLowerCase().contains(q) ||
        visibleToken(items[i]).toLowerCase().contains(q) ||
        (id != null && offset + i == id)) {
      out.add(i);
    }
  }
  return out;
}
