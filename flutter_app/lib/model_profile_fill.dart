import 'dart:convert';

import 'weight_ops_page.dart' show ggufFileTypeName;

/// Berkas Workspace yang bisa diisi dari header model GGUF lokal yang aktif.
/// Berkas lain tidak punya padanan di header GGUF, jadi tombol "Isi dari model lokal" nonaktif di sana.
const fillableFromModel = <String>{
  'model/config.json',
  'model/chat_template.jinja',
  'model/quantization.json',
  'chat/params.json',
};

bool canFillFromModel(String? path) => path != null && fillableFromModel.contains(path);

/// [text] null = tidak ada perubahan; [message] selalu berisi penjelasan singkat untuk pengguna.
class FillResult {
  const FillResult(this.text, this.message);
  final String? text;
  final String message;
}

const _indent = JsonEncoder.withIndent('    ');

int? _asInt(dynamic v) => v is num ? v.toInt() : null;

/// Isi [path] dari [profile] (hasil `Bridge.localModelProfile`). [current] = teks berkas sekarang di editor.
/// Hanya field yang benar-benar ada di header GGUF yang ditulis; field lain di berkas tetap utuh.
FillResult fillFromProfile(String path, String current, Map<String, dynamic> profile) {
  final name = '${profile['name'] ?? 'model'}';
  switch (path) {
    case 'model/chat_template.jinja': {
      final template = profile['chatTemplate'];
      if (template is! String || template.trim().isEmpty) {
        return FillResult(null, '$name tidak punya tokenizer.chat_template di headernya.');
      }
      if (template == current) return const FillResult(null, 'Template chat sudah sama dengan model.');
      return FillResult(template, 'Template chat diisi dari $name. Tekan Simpan untuk menyimpan.');
    }

    case 'model/config.json': {
      final base = _decodeObject(current);
      if (base == null) return const FillResult(null, 'config.json sekarang bukan JSON objek yang valid. Rapikan atau kosongkan dulu.');
      final fields = <String, dynamic>{
        'model_type': profile['architecture'],
        'max_position_embeddings': _asInt(profile['contextLength']),
        'hidden_size': _asInt(profile['embeddingLength']),
        'num_hidden_layers': _asInt(profile['blockCount']),
        'intermediate_size': _asInt(profile['feedForwardLength']),
        'num_attention_heads': _asInt(profile['headCount']),
        'num_key_value_heads': _asInt(profile['headCountKv']),
        'vocab_size': _asInt(profile['vocabSize']),
      }..removeWhere((_, v) => v == null || (v is String && v.isEmpty));
      if (fields.isEmpty) return FillResult(null, 'Header $name tidak memuat dimensi model yang dikenali.');
      final next = {...base, ...fields};
      final text = '${_indent.convert(next)}\n';
      if (_sameJson(base, next)) return const FillResult(null, 'config.json sudah sesuai dengan model.');
      return FillResult(text, 'config.json diisi dari $name (${fields.length} field). Tekan Simpan untuk menyimpan.');
    }

    case 'model/quantization.json': {
      final base = _decodeObject(current);
      if (base == null) return const FillResult(null, 'quantization.json sekarang bukan JSON objek yang valid. Rapikan atau kosongkan dulu.');
      final quant = ggufFileTypeName(_asInt(profile['fileType']));
      final next = <String, dynamic>{
        ...base,
        'modelPath': profile['path'],
        'format': base['format'] ?? 'GGUF',
        if (quant != null && !quant.startsWith('tipe ')) 'quantization': quant,
      };
      if (_sameJson(base, next)) return const FillResult(null, 'quantization.json sudah sesuai dengan model.');
      return FillResult('${_indent.convert(next)}\n', 'quantization.json diisi dari $name${quant == null ? '' : ' ($quant)'}. Tekan Simpan untuk menyimpan.');
    }

    case 'chat/params.json': {
      final base = _decodeObject(current);
      if (base == null) return const FillResult(null, 'params.json sekarang bukan JSON objek yang valid. Rapikan atau kosongkan dulu.');
      final modelCtx = _asInt(profile['contextLength']);
      if (modelCtx == null || modelCtx < 128) return FillResult(null, 'Header $name tidak memuat panjang konteks yang bisa dipakai.');
      final currentCtx = _asInt(base['contextLength']);
      if (currentCtx != null && currentCtx <= modelCtx) {
        return FillResult(null, 'contextLength ($currentCtx) sudah dalam batas konteks model ($modelCtx).');
      }
      final next = {...base, 'contextLength': modelCtx};
      return FillResult('${_indent.convert(next)}\n', 'contextLength diturunkan ke $modelCtx, batas konteks $name. Tekan Simpan untuk menyimpan.');
    }
  }
  return const FillResult(null, 'Berkas ini tidak bisa diisi dari model lokal.');
}

Map<String, dynamic>? _decodeObject(String text) {
  try {
    final decoded = jsonDecode(text.trim().isEmpty ? '{}' : text);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } catch (_) {
    return null;
  }
}

bool _sameJson(Map<String, dynamic> a, Map<String, dynamic> b) => jsonEncode(a) == jsonEncode(b);
