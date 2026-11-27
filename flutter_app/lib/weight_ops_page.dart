import 'package:flutter/material.dart';

import 'bridge.dart';
import 'errors.dart';
import 'theme.dart';

/// Nama tipe berkas (`general.file_type`) menurut llama.cpp. Tipe di luar daftar ditampilkan sebagai "tipe N".
const _fileTypeNames = <int, String>{
  0: 'F32',
  1: 'F16',
  2: 'Q4_0',
  3: 'Q4_1',
  7: 'Q8_0',
  8: 'Q5_0',
  9: 'Q5_1',
  10: 'Q2_K',
  11: 'Q3_K_S',
  12: 'Q3_K_M',
  13: 'Q3_K_L',
  14: 'Q4_K_S',
  15: 'Q4_K_M',
  16: 'Q5_K_S',
  17: 'Q5_K_M',
  18: 'Q6_K',
  32: 'BF16',
};

String? ggufFileTypeName(int? type) => type == null ? null : (_fileTypeNames[type] ?? 'tipe $type');

/// F32, F16, dan BF16 = bobot belum terkuantisasi. Selain itu, kuantisasi lagi perlu izin eksplisit (kualitas turun).
bool isFullPrecisionFileType(int? type) => type == 0 || type == 1 || type == 32;

/// Ambil `general.file_type` dari hasil `Bridge.ggufInspect`; null bila tidak ada atau tidak terbaca.
int? ggufFileTypeFromInspect(Map<String, dynamic> info) {
  for (final entry in (info['entries'] as List?) ?? const []) {
    if (entry is Map && entry['key'] == 'general.file_type') return int.tryParse('${entry['value']}');
  }
  return null;
}

/// Nama berkas yang aman di server: huruf, angka, titik, minus, garis bawah; tidak diawali tanda baca; maksimal 60 karakter.
String safeOpName(String raw, {String fallback = 'model'}) {
  final cleaned = raw
      .trim()
      .replaceAll(RegExp(r'\.gguf$', caseSensitive: false), '')
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
      .replaceFirst(RegExp(r'^[._-]+'), '');
  final cut = cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
  return cut.isEmpty ? fallback : cut;
}

/// Bobot merge dari teks. Null bila ada yang kosong, bukan angka, tidak berhingga, atau <= 0.
List<double>? parseMergeWeights(List<String> raw) {
  final out = <double>[];
  for (final text in raw) {
    final value = double.tryParse(text.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite || value <= 0) return null;
    out.add(value);
  }
  return out;
}

String _fmtSize(num n) {
  if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(2)} GB';
  if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(1)} MB';
  return '${(n / 1e3).toStringAsFixed(0)} KB';
}

const _quantChoices = ['Q2_K', 'Q3_K_M', 'Q4_K_M', 'Q5_K_M', 'Q6_K', 'Q8_0'];

/// Mengubah bobot model lewat server ModelOps (HTTPS): kuantisasi, menanam LoRA ke model, dan menggabung model.
/// Semua hasil disimpan sebagai model GGUF BARU di HP; model sumber tidak pernah diubah.
class WeightOpsPage extends StatefulWidget {
  const WeightOpsPage({super.key, required this.onLog});
  final void Function(String level, String message) onLog;

  @override
  State<WeightOpsPage> createState() => _WeightOpsPageState();
}

class _WeightOpsPageState extends State<WeightOpsPage> {
  bool _busy = false;
  String _status = '';
  List<String> _logs = const [];
  List<Map<String, dynamic>> _models = const [];
  List<Map<String, dynamic>> _adapters = const [];

  // Kuantisasi
  String? _quantPath;
  int? _quantSourceType;
  String _quant = 'Q4_K_M';
  bool _allowRequantize = false;

  // Tanam LoRA
  String? _loraBase;
  String? _loraAdapter;
  double _loraScale = 1;
  final _loraName = TextEditingController();

  // Gabung model
  final _mergeSources = <TextEditingController>[TextEditingController(), TextEditingController()];
  final _mergeWeights = <TextEditingController>[TextEditingController(text: '1'), TextEditingController(text: '1')];
  final _mergeName = TextEditingController();
  String _mergeQuant = 'Q4_K_M';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _loraName.dispose();
    _mergeName.dispose();
    for (final c in [..._mergeSources, ..._mergeWeights]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic>? _modelByPath(String? path) {
    for (final m in _models) {
      if ('${m['path']}' == path) return m;
    }
    return null;
  }

  Map<String, dynamic>? _adapterByPath(String? path) {
    for (final a in _adapters) {
      if ('${a['path']}' == path) return a;
    }
    return null;
  }

  Future<void> _load() async {
    try {
      final models = await Bridge.localModels();
      final list = await Bridge.loraList();
      if (!mounted) return;
      final adapters = ((list['adapters'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((a) => a['valid'] != false)
          .toList();
      setState(() {
        _models = models;
        _adapters = adapters;
        if (_modelByPath(_quantPath) == null) _quantPath = models.isEmpty ? null : '${models.first['path']}';
        if (_modelByPath(_loraBase) == null) _loraBase = models.isEmpty ? null : '${models.first['path']}';
        if (_adapterByPath(_loraAdapter) == null) _loraAdapter = adapters.isEmpty ? null : '${adapters.first['path']}';
      });
      await _loadQuantSourceType(_quantPath);
    } catch (e) {
      if (mounted) setState(() => _status = friendlyError(e));
    }
  }

  Future<void> _loadQuantSourceType(String? path) async {
    if (path == null) return;
    try {
      final info = await Bridge.ggufInspect(path);
      if (!mounted || _quantPath != path) return;
      setState(() => _quantSourceType = ggufFileTypeFromInspect(info));
    } catch (_) {
      // Tipe tidak terbaca: biarkan tidak diketahui, server tetap menolak bila perlu.
    }
  }

  Future<void> _run(Future<void> Function() job) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '';
      _logs = const [];
    });
    try {
      await job();
    } catch (e) {
      widget.onLog('ERROR', 'Ubah bobot: ${friendlyError(e)}');
      if (mounted) setState(() => _status = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: panel,
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lanjutkan')),
          ],
        ),
      ) ??
      false;

  Future<void> _finish(Map<String, dynamic> result, String label) async {
    final logs = ((result['logs'] as List?) ?? const []).map((e) => '$e').toList();
    final path = '${result['outputPath'] ?? ''}';
    final name = path.split('/').last;
    widget.onLog('INFO', '$label: $name');
    await _load();
    if (!mounted) return;
    setState(() {
      _logs = logs;
      _status = '$label. Model baru: $name. Model sumber tidak diubah.';
    });
  }

  // ---------- Kuantisasi ----------
  bool get _quantNeedsRequantize => _quantSourceType != null && !isFullPrecisionFileType(_quantSourceType);
  bool get _quantSameType => ggufFileTypeName(_quantSourceType) == _quant;
  bool get _quantReady =>
      _quantPath != null && !_quantSameType && (!_quantNeedsRequantize || _allowRequantize);

  Future<void> _quantize() async {
    final path = _quantPath;
    final model = _modelByPath(path);
    if (path == null || model == null) return;
    final ok = await _confirm(
      'Kuantisasi model?',
      'Bobot ${model['name']} (${_fmtSize((model['size'] as num?) ?? 0)}) diunggah ke server ModelOps. Hasil ($_quant) disimpan sebagai model baru; model sumber tidak ditimpa. Pastikan koneksi HTTPS dan ruang server cukup.',
    );
    if (!ok) return;
    await _run(() async {
      final base = safeOpName('${model['name']}');
      final result = await Bridge.runModelOperation({
        'op': 'QUANTIZE',
        'source': path,
        'output': 'outputs/$base-$_quant.gguf',
        'quantization': _quant,
        'allowRequantize': _allowRequantize,
      });
      await _finish(result, 'Kuantisasi $_quant selesai');
    });
  }

  // ---------- Tanam LoRA ----------
  bool get _loraReady => _loraBase != null && _loraAdapter != null;

  Future<void> _mergeLora() async {
    final basePath = _loraBase;
    final adapterPath = _loraAdapter;
    final base = _modelByPath(basePath);
    final adapter = _adapterByPath(adapterPath);
    if (basePath == null || adapterPath == null || base == null || adapter == null) return;
    final total = ((base['size'] as num?) ?? 0) + ((adapter['size'] as num?) ?? 0);
    final ok = await _confirm(
      'Tanam adapter ke model?',
      '${base['name']} dan ${adapter['name']} (total ${_fmtSize(total)}) diunggah ke server. Hasilnya model GGUF baru dengan adapter sudah menyatu (skala ${_loraScale.toStringAsFixed(2)}); keduanya tidak diubah.',
    );
    if (!ok) return;
    await _run(() async {
      final name = safeOpName(_loraName.text, fallback: '${safeOpName('${base['name']}')}-lora');
      final result = await Bridge.runModelOperation({
        'op': 'MERGE_LORA_GGUF',
        'source': basePath,
        'adapter': adapterPath,
        'output': 'outputs/$name.gguf',
        'loraScale': _loraScale,
      });
      await _finish(result, 'Adapter berhasil ditanam');
    });
  }

  // ---------- Gabung model ----------
  void _addMergeRow() {
    if (_mergeSources.length >= 6) return;
    setState(() {
      _mergeSources.add(TextEditingController());
      _mergeWeights.add(TextEditingController(text: '1'));
    });
  }

  void _removeMergeRow(int index) {
    if (_mergeSources.length <= 2) return;
    setState(() {
      _mergeSources.removeAt(index).dispose();
      _mergeWeights.removeAt(index).dispose();
    });
  }

  /// Pesan masalah input gabung model, atau null bila siap dijalankan.
  String? _mergeProblem() {
    final sources = _mergeSources.map((c) => c.text.trim()).toList();
    if (sources.any((s) => s.isEmpty)) return 'Isi semua baris model.';
    if (sources.toSet().length != sources.length) return 'Ada model yang sama di dua baris.';
    if (sources.any((s) => s.endsWith('.gguf'))) {
      return 'Gabung model memakai bobot penuh (safetensors), bukan file GGUF. Isi id repo Hugging Face atau nama folder model di server.';
    }
    if (parseMergeWeights(_mergeWeights.map((c) => c.text).toList()) == null) return 'Bobot harus angka lebih besar dari 0.';
    return null;
  }

  Future<void> _mergeModels() async {
    final problem = _mergeProblem();
    if (problem != null) {
      setState(() => _status = problem);
      return;
    }
    final ok = await _confirm(
      'Gabung model di server?',
      'Server memuat bobot penuh semua model, merata-ratakannya, mengonversi ke GGUF F16${_mergeQuant == 'F16' ? '' : ', lalu kuantisasi $_mergeQuant'}. '
          'Butuh RAM server sekitar 4-5x ukuran model dalam FP16 dan bisa berjalan lama (menit sampai jam). Biarkan aplikasi terbuka sampai selesai. '
          'Hasil antara dihapus dari server setelahnya.',
    );
    if (!ok) return;
    await _run(() async {
      final result = await Bridge.runModelPipeline({
        'name': safeOpName(_mergeName.text, fallback: 'merged'),
        'sources': _mergeSources.map((c) => c.text.trim()).toList(),
        'weights': parseMergeWeights(_mergeWeights.map((c) => c.text).toList()),
        'quant': _mergeQuant,
      });
      await _finish(result, 'Gabung model selesai');
    });
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_busy) const LinearProgressIndicator(minHeight: 2),
      const Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: Text(
          'Operasi bobot berjalan di server HTTPS yang diatur di halaman Latih, bukan di ponsel. Hasil diunduh sebagai model baru.',
          style: TextStyle(color: muted, fontSize: 12, height: 1.4),
        ),
      ),
      _quantizeCard(),
      const SizedBox(height: 10),
      _loraCard(),
      const SizedBox(height: 10),
      _mergeCard(),
      if (_busy)
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text('Berjalan di server. Biarkan aplikasi terbuka sampai selesai.', style: TextStyle(color: amber, fontSize: 12)),
        ),
      if (_status.isNotEmpty)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(9)),
          child: SelectableText(_status, style: const TextStyle(fontSize: 11, height: 1.4)),
        ),
      if (_logs.isNotEmpty)
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Log server', style: TextStyle(fontSize: 12, color: muted)),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(9)),
                child: SelectableText(_logs.join('\n'), style: const TextStyle(fontSize: 10, fontFamily: 'monospace', height: 1.35)),
              ),
            ],
          ),
        ),
    ]);
  }

  Widget _card(String title, String detail, {required IconData icon, required Widget child}) => Card(
        color: panel,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: purple),
              const SizedBox(width: 9),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
            ]),
            const SizedBox(height: 8),
            Text(detail, style: const TextStyle(color: muted, height: 1.4, fontSize: 12)),
            const SizedBox(height: 14),
            child,
          ]),
        ),
      );

  Widget _modelDropdown({required String label, required String? value, required ValueChanged<String?> onChanged}) {
    return DropdownButtonFormField<String>(
      isExpanded: true,
      value: _modelByPath(value) == null ? null : value,
      decoration: InputDecoration(labelText: label),
      items: _models
          .map((m) => DropdownMenuItem(value: '${m['path']}', child: Text('${m['name']}', overflow: TextOverflow.ellipsis)))
          .toList(),
      onChanged: _busy ? null : onChanged,
    );
  }

  Widget _quantizeCard() {
    final typeName = ggufFileTypeName(_quantSourceType);
    return _card(
      'Kuantisasi',
      'Perkecil model dengan format kuantisasi lain. Hasil terbaik dari model F16/BF16.',
      icon: Icons.compress,
      child: _models.isEmpty
          ? const Text('Belum ada model lokal. Unduh atau impor model GGUF dulu.', style: TextStyle(fontSize: 12, color: muted))
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _modelDropdown(
                label: 'Model sumber',
                value: _quantPath,
                onChanged: (v) {
                  setState(() {
                    _quantPath = v;
                    _quantSourceType = null;
                    _allowRequantize = false;
                  });
                  _loadQuantSourceType(v);
                },
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _quant,
                decoration: const InputDecoration(labelText: 'Format tujuan'),
                items: _quantChoices.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                onChanged: _busy ? null : (v) => setState(() => _quant = v ?? 'Q4_K_M'),
              ),
              const SizedBox(height: 8),
              Text(
                typeName == null ? 'Tipe sumber tidak terbaca dari header.' : 'Tipe sumber: $typeName',
                style: const TextStyle(fontSize: 11, color: muted),
              ),
              if (_quantNeedsRequantize) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Izinkan kuantisasi ulang', style: TextStyle(fontSize: 12)),
                  subtitle: Text(
                    'Sumber sudah $typeName. Menguantisasi ulang model yang sudah terkuantisasi menurunkan kualitas; bila ada versi F16/BF16, pakai itu.',
                    style: const TextStyle(fontSize: 11, color: amber, height: 1.35),
                  ),
                  value: _allowRequantize,
                  onChanged: _busy ? null : (v) => setState(() => _allowRequantize = v),
                ),
              ],
              if (_quantSameType)
                const Text('Format tujuan sama dengan sumber. Pilih format lain.', style: TextStyle(fontSize: 11, color: amber)),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _busy || !_quantReady ? null : _quantize,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Kuantisasi · simpan sebagai model baru'),
              ),
            ]),
    );
  }

  Widget _loraCard() {
    final adapter = _adapterByPath(_loraAdapter);
    final mismatch = adapter != null && adapter['compatible'] == false;
    return _card(
      'Tanam adapter LoRA ke model',
      'Menyatukan adapter GGUF ke model dasar menjadi satu model baru, jadi tidak perlu memasang adapter lagi. Adapter berasal dari layar LoRA.',
      icon: Icons.merge_type,
      child: _models.isEmpty || _adapters.isEmpty
          ? Text(
              _models.isEmpty ? 'Belum ada model lokal.' : 'Belum ada adapter. Impor adapter .gguf di layar LoRA.',
              style: const TextStyle(fontSize: 12, color: muted),
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _modelDropdown(label: 'Model dasar', value: _loraBase, onChanged: (v) => setState(() => _loraBase = v)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                isExpanded: true,
                value: _adapterByPath(_loraAdapter) == null ? null : _loraAdapter,
                decoration: const InputDecoration(labelText: 'Adapter'),
                items: _adapters
                    .map((a) => DropdownMenuItem(value: '${a['path']}', child: Text('${a['name']}', overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: _busy ? null : (v) => setState(() => _loraAdapter = v),
              ),
              if (mismatch)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Adapter ini ditandai tidak cocok dengan model aktif. Pastikan arsitekturnya sama dengan model dasar yang dipilih di sini.',
                    style: TextStyle(fontSize: 11, color: amber, height: 1.35),
                  ),
                ),
              const SizedBox(height: 8),
              Text('Skala: ${_loraScale.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12)),
              Slider(
                value: _loraScale.clamp(0.0, 2.0).toDouble(),
                min: 0,
                max: 2,
                divisions: 40,
                label: _loraScale.toStringAsFixed(2),
                onChanged: _busy ? null : (v) => setState(() => _loraScale = v),
              ),
              TextField(
                controller: _loraName,
                enabled: !_busy,
                decoration: const InputDecoration(labelText: 'Nama hasil (opsional)', hintText: 'mis. model-dengan-adapter'),
              ),
              const SizedBox(height: 6),
              const Text(
                'Paling andal pada model dasar F16/F32. Pada model terkuantisasi, llama.cpp bisa menolak atau hasilnya turun kualitas; bila gagal, pakai versi F16 lalu kuantisasi hasilnya.',
                style: TextStyle(fontSize: 11, color: muted, height: 1.35),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _busy || !_loraReady ? null : _mergeLora,
                icon: const Icon(Icons.merge_type),
                label: const Text('Tanam · simpan sebagai model baru'),
              ),
            ]),
    );
  }

  Widget _mergeCard() {
    return _card(
      'Gabung model',
      'Rata-rata berbobot dua model atau lebih yang berarsitektur sama, mis. dua fine-tune dari model dasar yang sama. Memakai bobot penuh, bukan file GGUF di HP.',
      icon: Icons.call_merge,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < _mergeSources.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TextField(
                  controller: _mergeSources[i],
                  enabled: !_busy,
                  decoration: InputDecoration(labelText: 'Model ${i + 1}', hintText: 'Qwen/Qwen2.5-0.5B-Instruct'),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: TextField(
                  controller: _mergeWeights[i],
                  enabled: !_busy,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Bobot'),
                ),
              ),
              if (_mergeSources.length > 2)
                IconButton(
                  tooltip: 'Hapus baris',
                  onPressed: _busy ? null : () => _removeMergeRow(i),
                  icon: const Icon(Icons.close, size: 18),
                ),
            ]),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy || _mergeSources.length >= 6 ? null : _addMergeRow,
            icon: const Icon(Icons.add),
            label: const Text('Tambah model'),
          ),
        ),
        const Text(
          'Isi id repo Hugging Face atau nama folder model yang sudah ada di server. Bobot dinormalkan otomatis (1 dan 1 = rata-rata biasa).',
          style: TextStyle(fontSize: 11, color: muted, height: 1.35),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _mergeName,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: 'Nama hasil (opsional)', hintText: 'merged'),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _mergeQuant,
          decoration: const InputDecoration(labelText: 'Format hasil'),
          items: ['F16', ..._quantChoices]
              .map((v) => DropdownMenuItem(value: v, child: Text(v == 'F16' ? 'F16 (tanpa kuantisasi, besar)' : v)))
              .toList(),
          onChanged: _busy ? null : (v) => setState(() => _mergeQuant = v ?? 'Q4_K_M'),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: _busy ? null : _mergeModels,
          icon: const Icon(Icons.call_merge),
          label: const Text('Gabung · simpan sebagai model baru'),
        ),
      ]),
    );
  }
}
