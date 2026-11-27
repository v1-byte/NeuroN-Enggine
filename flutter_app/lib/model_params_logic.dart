import 'dart:convert';

/// Logika murni form parameter per model. Rentang sama dengan ModelParamOverride.problem() di Kotlin;
/// Kotlin tetap yang memutuskan, ini hanya agar kesalahan muncul sebelum dikirim.
class ParamField {
  const ParamField(this.key, this.label, this.hint, {this.integer = false, this.min, this.max, this.minExclusive = false});

  /// Kunci JSON = nama field ChatParams (camelCase).
  final String key;
  final String label;
  final String hint;
  final bool integer;
  final num? min;
  final num? max;
  final bool minExclusive;
}

const paramFields = <ParamField>[
  ParamField('temperature', 'Temperature', '0 – 5', min: 0, max: 5),
  ParamField('topP', 'Top-p', '0 – 1', min: 0, max: 1),
  ParamField('topK', 'Top-k', 'bilangan bulat ≥ 0', integer: true, min: 0),
  ParamField('minP', 'Min-p', '0 – 1', min: 0, max: 1),
  ParamField('repeatPenalty', 'Repeat penalty', '> 0', min: 0, minExclusive: true),
  ParamField('maxTokens', 'Max tokens', 'bilangan bulat > 0', integer: true, min: 1),
  ParamField('seed', 'Seed', 'bilangan bulat; -1 = acak', integer: true),
  ParamField('contextLength', 'Panjang konteks', 'bilangan bulat ≥ 256 (berlaku setelah model dimuat ulang)', integer: true, min: 256),
];

/// Pesan kesalahan untuk isi satu kolom, atau null bila valid. Kolom kosong valid: berarti "ikut proyek".
String? validateParam(ParamField f, String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  final n = f.integer ? int.tryParse(t) : double.tryParse(t.replaceAll(',', '.'));
  if (n == null || (n is double && !n.isFinite)) {
    return f.integer ? 'Harus bilangan bulat' : 'Harus berupa angka';
  }
  if (f.min != null) {
    if (f.minExclusive ? n <= f.min! : n < f.min!) {
      return f.minExclusive ? 'Harus > ${f.min}' : 'Minimal ${f.min}';
    }
  }
  if (f.max != null && n > f.max!) return 'Maksimal ${f.max}';
  return null;
}

/// Hasil membaca seluruh form: nilai yang terisi dan kesalahan per kunci.
class ParamsForm {
  const ParamsForm(this.values, this.errors);
  final Map<String, num> values;
  final Map<String, String> errors;

  bool get ok => errors.isEmpty;

  /// JSON untuk bridge. Kolom kosong tidak ikut dikirim; `{}` berarti tanpa penimpas.
  String get json => jsonEncode(values);
}

ParamsForm readParamsForm(Map<String, String> texts) {
  final values = <String, num>{};
  final errors = <String, String>{};
  for (final f in paramFields) {
    final raw = (texts[f.key] ?? '').trim();
    final err = validateParam(f, raw);
    if (err != null) {
      errors[f.key] = err;
    } else if (raw.isNotEmpty) {
      values[f.key] = f.integer ? int.parse(raw) : double.parse(raw.replaceAll(',', '.'));
    }
  }
  return ParamsForm(values, errors);
}

/// Teks awal kolom dari penimpas tersimpan. Angka bulat ditampilkan tanpa ".0".
Map<String, String> formTexts(Map<String, dynamic> overrides) => {
      for (final f in paramFields)
        if (overrides[f.key] is num) f.key: shownNumber(overrides[f.key] as num, integer: f.integer),
    };

String shownNumber(num v, {bool integer = false}) {
  if (integer) return v.toInt().toString();
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toString();
}

/// Apakah menyimpan [next] mengubah panjang konteks dibanding yang tersimpan [saved]; berarti model dimuat ulang.
bool contextWillChange(Map<String, dynamic> saved, Map<String, num> next) {
  final a = (saved['contextLength'] as num?)?.toInt();
  final b = next['contextLength']?.toInt();
  return a != b;
}
