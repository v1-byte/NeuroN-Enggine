import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'bridge.dart';
import 'errors.dart';
import 'theme.dart';

/// Nama template yang dikenali llama.cpp (llama_chat_apply_template). Menulis salah satunya ke
/// `tokenizer.chat_template` membuat engine memakai format itu, tanpa perlu interpreter Jinja.
const _templatePresets = <String>['chatml', 'llama3', 'gemma', 'phi3', 'zephyr', 'llama2', 'deepseek'];

const _addTypes = <String>['string', 'bool', 'uint32', 'int32', 'uint64', 'int64', 'float32', 'float64'];

String _fmtCount(num n) {
  final s = n.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return b.toString();
}

String _fmtParams(num n) {
  if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(2)} miliar';
  if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(0)} juta';
  return _fmtCount(n);
}

String _fmtBytes(num n) {
  if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(2)} GB';
  if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(0)} MB';
  return '${(n / 1e3).toStringAsFixed(0)} KB';
}

/// Editor metadata GGUF di perangkat. Yang diubah adalah header (nama, template chat, ID token khusus, dll.);
/// bobot model disalin utuh ke berkas baru. Model asli tidak pernah ditimpa.
class GgufEditorPage extends StatefulWidget {
  const GgufEditorPage({super.key, required this.onLog, this.initialPath});
  final void Function(String level, String message) onLog;
  final String? initialPath;

  @override
  State<GgufEditorPage> createState() => _GgufEditorPageState();
}

class _GgufEditorPageState extends State<GgufEditorPage> {
  List<Map<String, dynamic>> _models = [];
  String? _path;
  Map<String, dynamic> _info = const {};
  List<Map<String, dynamic>> _entries = [];
  // Perubahan yang belum disimpan, per key: {type, value, delete, isNew}.
  final Map<String, Map<String, dynamic>> _pending = {};
  final _search = TextEditingController();
  bool _loading = false;
  bool _saving = false;
  bool _importing = false;
  bool _activate = true;
  double _progress = 0;
  String _status = '';
  Timer? _poll;
  int _openReq = 0;
  // Tabel tensor (dimuat bertahap saat bagian "Tensor" dibuka).
  final _tensorSearch = TextEditingController();
  Timer? _tensorDebounce;
  List<Map<String, dynamic>> _tensors = [];
  int _tensorMatched = 0;
  int _tensorReq = 0;
  bool _tensorsLoading = false;
  String? _tensorError;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tensorDebounce?.cancel();
    _search.dispose();
    _tensorSearch.dispose();
    super.dispose();
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _loadModels() async {
    setState(() => _loading = true);
    try {
      final models = await Bridge.localModels(hash: false);
      if (!mounted) return;
      setState(() {
        _models = models;
        _loading = false;
      });
      final want = widget.initialPath ?? _path;
      if (want != null && models.any((m) => m['path'] == want)) {
        await _open(want);
      } else if (want != null) {
        setState(() => _status = 'Model yang dipilih tidak ditemukan di penyimpanan NeuroN (mungkin sudah dihapus atau diganti nama). Pilih dari daftar.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = friendlyError(e);
      });
    }
  }

  Future<void> _open(String path) async {
    if (_pending.isNotEmpty && _path != path) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Buang perubahan?'),
          content: Text('${_pending.length} perubahan belum disimpan akan hilang.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Buang')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final req = ++_openReq;
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      final info = await Bridge.ggufInspect(path);
      final entries = ((info['entries'] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      if (!mounted || req != _openReq) return; // pengguna sudah memilih model lain
      _tensorReq++;
      _tensorSearch.clear();
      setState(() {
        _path = path;
        _info = info;
        _entries = entries;
        _tensors = [];
        _tensorMatched = 0;
        _tensorsLoading = false;
        _tensorError = null;
        _pending.clear();
        _loading = false;
      });
    } catch (e) {
      widget.onLog('ERROR', 'Gagal membaca model GGUF: $e');
      if (!mounted || req != _openReq) return;
      setState(() {
        _loading = false;
        _status = friendlyError(e);
      });
    }
  }

  /// Pilih .gguf dari penyimpanan HP. Berkas disalin ke penyimpanan NeuroN (tanpa mengganti model aktif), lalu dibuka.
  Future<void> _pickFromDevice() async {
    if (_saving || _importing) return;
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['gguf'], withData: false);
    final source = picked?.files.single.path;
    if (source == null) return;
    setState(() {
      _importing = true;
      _status = 'Menyalin model ke penyimpanan NeuroN…';
    });
    try {
      final r = await Bridge.importLocalModel(source);
      widget.onLog('INFO', 'Model GGUF diimpor untuk diedit: ${r['name']}');
      final models = await Bridge.localModels(hash: false);
      if (!mounted) return;
      setState(() {
        _models = models;
        _importing = false;
        _status = '';
      });
      await _open('${r['path']}');
    } catch (e) {
      widget.onLog('ERROR', 'Gagal mengimpor model GGUF: $e');
      if (!mounted) return;
      setState(() {
        _importing = false;
        _status = friendlyError(e);
      });
    }
  }

  Map<String, dynamic>? _entry(String key) {
    for (final e in _entries) {
      if (e['key'] == key) return e;
    }
    return null;
  }

  String get _arch => (_entry('general.architecture')?['value'] as String?) ?? '?';

  // ---------- Perubahan ----------

  void _setValue(String key, String type, String value, {bool isNew = false}) {
    final original = _entry(key)?['value'];
    setState(() {
      if (!isNew && original == value) {
        _pending.remove(key);
      } else {
        _pending[key] = {'type': type, 'value': value, 'delete': false, 'isNew': isNew};
      }
    });
  }

  void _markDelete(String key) => setState(() {
        if (_pending[key]?['isNew'] == true) {
          _pending.remove(key);
        } else {
          _pending[key] = {'type': _entry(key)?['type'], 'value': '', 'delete': true, 'isNew': false};
        }
      });

  Future<void> _editEntry(Map<String, dynamic> e) async {
    final key = e['key'] as String;
    final type = e['type'] as String;
    if (e['editable'] != true) {
      final note = (e['note'] as String?) ?? '';
      _say(note.isEmpty ? '$key tidak bisa diedit.' : note);
      return;
    }
    final p = _pending[key];
    final current = p != null && p['delete'] != true ? '${p['value']}' : '${e['value'] ?? ''}';
    final result = await _valueDialog(key: key, type: type, initial: current, canDelete: true);
    if (result == null) return;
    if (result == _deleteToken) {
      _markDelete(key);
    } else {
      _setValue(key, type, result, isNew: p?['isNew'] == true);
    }
  }

  static const _deleteToken = '\u0000delete';

  Future<String?> _valueDialog({required String key, required String type, required String initial, required bool canDelete}) {
    final c = TextEditingController(text: initial);
    String boolValue = initial.toLowerCase() == 'true' ? 'true' : 'false';
    final isString = type == 'string';
    final isBool = type == 'bool';
    final isFloat = type.startsWith('float');
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(key, style: const TextStyle(fontSize: 14)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Tipe: $type', style: const TextStyle(color: muted, fontSize: 12)),
              const SizedBox(height: 8),
              if (isBool)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(boolValue),
                  value: boolValue == 'true',
                  onChanged: (v) => setD(() => boolValue = v ? 'true' : 'false'),
                )
              else
                TextField(
                  controller: c,
                  autofocus: true,
                  minLines: isString ? 3 : 1,
                  maxLines: isString ? 14 : 1,
                  keyboardType: isString
                      ? TextInputType.multiline
                      : TextInputType.numberWithOptions(decimal: isFloat, signed: !type.startsWith('uint')),
                  style: TextStyle(fontFamily: isString ? 'monospace' : null, fontSize: 13),
                ),
              if (key == 'tokenizer.chat_template') ...[
                const SizedBox(height: 10),
                const Text('Format bawaan llama.cpp:', style: TextStyle(color: muted, fontSize: 12)),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 0, children: [
                  for (final t in _templatePresets) ActionChip(label: Text(t), onPressed: () => setD(() => c.text = t)),
                ]),
                const SizedBox(height: 6),
                const Text(
                  'Engine memakai template ini lewat llama.cpp. Template Jinja bebas yang tidak dikenali tetap jatuh ke ChatML.',
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ],
            ]),
          ),
          actions: [
            if (canDelete) TextButton(onPressed: () => Navigator.pop(ctx, _deleteToken), child: const Text('Hapus key', style: TextStyle(color: errorRed))),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, isBool ? boolValue : c.text), child: const Text('Terapkan')),
          ],
        ),
      ),
    );
  }

  Future<void> _addKey() async {
    final keyC = TextEditingController();
    String type = 'string';
    final ready = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Tambah key'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: keyC, autofocus: true, decoration: const InputDecoration(labelText: 'Nama key', hintText: 'general.description')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: type,
              items: [for (final t in _addTypes) DropdownMenuItem(value: t, child: Text(t))],
              onChanged: (v) => setD(() => type = v ?? 'string'),
              decoration: const InputDecoration(labelText: 'Tipe'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lanjut')),
          ],
        ),
      ),
    );
    final key = keyC.text.trim();
    if (ready != true || key.isEmpty) return;
    if (!RegExp(r'^[A-Za-z0-9._-]{1,255}$').hasMatch(key)) {
      _say('Nama key hanya boleh huruf, angka, titik, garis bawah, dan minus.');
      return;
    }
    if (_entry(key) != null) {
      _say('Key sudah ada; ubah lewat daftar.');
      return;
    }
    final value = await _valueDialog(key: key, type: type, initial: type == 'bool' ? 'false' : '', canDelete: false);
    if (value == null) return;
    _setValue(key, type, value, isNew: true);
  }

  Future<void> _templateShortcut() async {
    final cur = _entry('tokenizer.chat_template');
    if (cur != null && cur['editable'] == true) {
      await _editEntry(cur);
    } else if (cur == null) {
      final v = await _valueDialog(key: 'tokenizer.chat_template', type: 'string', initial: 'chatml', canDelete: false);
      if (v != null) _setValue('tokenizer.chat_template', 'string', v, isNew: true);
    } else {
      _say('Template chat di model ini tidak bisa diedit di sini.');
    }
  }

  // ---------- Baca total: tensor dan isi array ----------

  Future<void> _loadTensors({bool reset = false}) async {
    final path = _path;
    if (path == null) return;
    if (!reset && _tensorsLoading) return;
    final req = ++_tensorReq;
    final query = _tensorSearch.text.trim();
    final offset = reset ? 0 : _tensors.length;
    setState(() {
      _tensorsLoading = true;
      _tensorError = null;
      if (reset) {
        _tensors = [];
        _tensorMatched = 0;
      }
    });
    try {
      final r = await Bridge.ggufTensors(path, query: query, offset: offset, limit: 100);
      if (!mounted || req != _tensorReq) return;
      final items = ((r['items'] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      setState(() {
        _tensors = reset ? items : [..._tensors, ...items];
        _tensorMatched = (r['matched'] as num?)?.toInt() ?? _tensors.length;
        _tensorsLoading = false;
      });
    } catch (e) {
      widget.onLog('ERROR', 'Gagal membaca tabel tensor: $e');
      if (!mounted || req != _tensorReq) return;
      setState(() {
        _tensorsLoading = false;
        _tensorError = friendlyError(e);
      });
    }
  }

  void _onTensorQuery(String _) {
    _tensorDebounce?.cancel();
    _tensorDebounce = Timer(const Duration(milliseconds: 350), () => _loadTensors(reset: true));
  }

  Future<void> _viewArray(Map<String, dynamic> e) async {
    final path = _path;
    if (path == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _ArrayViewerDialog(path: path, keyName: e['key'] as String, elemType: '${e['elemType']}', count: (e['count'] as num?)?.toInt() ?? 0),
    );
  }

  // ---------- Simpan ----------

  Future<void> _save() async {
    final path = _path;
    if (path == null || _pending.isEmpty || _saving) return;
    final size = (_info['size'] as num?) ?? 0;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Simpan salinan model?'),
        content: Text(
          'Model asli tidak diubah. Aplikasi menulis salinan baru (${_fmtBytes(size)}) dengan ${_pending.length} perubahan metadata. '
          'Pastikan ruang kosong cukup; proses bisa memakan waktu beberapa menit untuk model besar.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan')),
        ],
      ),
    );
    if (go != true) return;
    setState(() {
      _saving = true;
      _progress = 0;
      _status = 'Menyalin model…';
    });
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      try {
        final p = await Bridge.ggufProgress();
        final total = (p['total'] as num?)?.toDouble() ?? 0;
        final done = (p['done'] as num?)?.toDouble() ?? 0;
        if (mounted && total > 0) setState(() => _progress = (done / total).clamp(0.0, 1.0));
      } catch (_) {}
    });
    try {
      final edits = [
        for (final e in _pending.entries)
          {'key': e.key, 'type': e.value['type'] ?? '', 'value': e.value['value'] ?? '', 'delete': e.value['delete'] == true},
      ];
      final r = await Bridge.ggufSave(path, edits, activate: _activate);
      widget.onLog('INFO', 'Metadata GGUF disimpan: ${r['name']} (${_pending.length} perubahan)');
      _poll?.cancel();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _status = _activate ? 'Tersimpan dan diaktifkan: ${r['name']}' : 'Tersimpan: ${r['name']}';
      });
      await _loadModelsKeep(r['path'] as String?);
    } catch (e) {
      _poll?.cancel();
      widget.onLog('ERROR', 'Gagal menyimpan metadata GGUF: $e');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _status = friendlyError(e);
      });
    }
  }

  Future<void> _loadModelsKeep(String? newPath) async {
    final models = await Bridge.localModels(hash: false);
    if (!mounted) return;
    setState(() => _models = models);
    if (newPath != null) {
      _pending.clear();
      await _open(newPath);
    }
  }

  Future<void> _cancelSave() async {
    try {
      await Bridge.ggufCancel();
    } catch (_) {}
  }

  // ---------- UI ----------

  bool _matches(Map<String, dynamic> e) {
    final q = _search.text.trim().toLowerCase();
    return q.isEmpty || (e['key'] as String).toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _entries.where(_matches).toList();
    final newKeys = _pending.entries.where((e) => e.value['isNew'] == true).map((e) => e.key).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Editor GGUF', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text('Baca isi model lokal secara total (metadata, tensor, token) dan ubah metadata: nama, template chat, ID token khusus. Bobot model tidak diubah.',
          style: TextStyle(color: muted, fontSize: 12)),
      const SizedBox(height: 12),
      if (_models.isEmpty && !_loading)
        const Text('Belum ada model GGUF lokal. Pilih file dari HP di bawah, atau unduh lewat Model Hub.', style: TextStyle(color: muted))
      else
        DropdownButtonFormField<String>(
          value: _models.any((m) => m['path'] == _path) ? _path : null,
          isExpanded: true,
          hint: const Text('Pilih model'),
          items: [
            for (final m in _models)
              DropdownMenuItem(
                value: m['path'] as String,
                child: Text('${m['name']} · ${_fmtBytes((m['size'] as num?) ?? 0)}${m['active'] == true ? ' · aktif' : ''}', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _saving ? null : (v) => v == null ? null : _open(v),
          decoration: const InputDecoration(labelText: 'Model'),
        ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: (_saving || _importing) ? null : _pickFromDevice,
          icon: const Icon(Icons.folder_open_outlined, size: 18),
          label: const Text('Pilih file .gguf dari HP'),
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('File disalin dulu ke penyimpanan NeuroN (butuh ruang sebesar model); model aktif tidak berubah.',
            style: TextStyle(color: muted, fontSize: 11)),
      ),
      if (_loading || _importing) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator(minHeight: 2)),
      if (_status.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(_status, style: TextStyle(color: _status.startsWith('Tersimpan') || _status.startsWith('Menyalin') ? green : errorRed, fontSize: 13)),
        ),
      if (_path != null && _entries.isNotEmpty) ...[
        const SizedBox(height: 10),
        _summary(),
        const SizedBox(height: 10),
        _tensorSection(),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 18), hintText: 'Cari key', isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.outlined(tooltip: 'Template chat', onPressed: _saving ? null : _templateShortcut, icon: const Icon(Icons.chat_outlined, size: 18)),
          IconButton.outlined(tooltip: 'Tambah key', onPressed: _saving ? null : _addKey, icon: const Icon(Icons.add, size: 18)),
        ]),
        const SizedBox(height: 8),
        for (final k in newKeys) _row({'key': k, 'type': _pending[k]!['type'], 'value': _pending[k]!['value'], 'editable': true, 'note': ''}),
        for (final e in shown) _row(e),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Aktifkan salinan setelah disimpan', style: TextStyle(fontSize: 13)),
          value: _activate,
          onChanged: _saving ? null : (v) => setState(() => _activate = v),
        ),
        if (_saving) ...[
          LinearProgressIndicator(value: _progress > 0 ? _progress : null, minHeight: 4),
          const SizedBox(height: 6),
          Row(children: [
            Text('${(_progress * 100).toStringAsFixed(0)}%', style: const TextStyle(color: muted, fontSize: 12)),
            const Spacer(),
            TextButton(onPressed: _cancelSave, child: const Text('Batal')),
          ]),
        ] else
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _pending.isEmpty ? null : _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(_pending.isEmpty ? 'Belum ada perubahan' : 'Simpan salinan (${_pending.length})'),
              ),
            ),
            if (_pending.isNotEmpty) ...[
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => setState(_pending.clear), child: const Text('Reset')),
            ],
          ]),
        const SizedBox(height: 24),
      ],
    ]);
  }

  Widget _summary() {
    final params = _info['params'] as num?;
    final layers = _info['layers'] as num?;
    final fileType = _info['fileTypeName'] as String?;
    final byType = ((_info['byType'] as List?) ?? const []).whereType<Map>().toList();
    final issues = ((_info['issues'] as List?) ?? const []).map((e) => '$e').toList();
    final dataBytes = (_info['dataBytes'] as num?) ?? 0;
    final tokens = (_info['tokenCount'] as num?) ?? -1;
    final head = [
      'Arsitektur $_arch',
      'GGUF v${_info['version']}',
      if (fileType != null) fileType,
      if (params != null) '${_fmtParams(params)} parameter',
      if (layers != null && layers > 0) '${layers.toInt()} blok',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(10), border: Border.all(color: line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(head, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          '${_fmtCount((_info['tensorCount'] as num?) ?? 0)} tensor · ${_entries.length} key'
          '${tokens >= 0 ? ' · ${_fmtCount(tokens)} token' : ''} · ${_fmtBytes((_info['size'] as num?) ?? 0)}',
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        if (byType.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final t in byType)
            Text('${t['type']}  ·  ${_fmtCount((t['count'] as num?) ?? 0)} tensor  ·  ${_fmtBytes((t['bytes'] as num?) ?? 0)}',
                style: const TextStyle(color: muted, fontSize: 11, fontFamily: 'monospace')),
        ],
        const SizedBox(height: 8),
        if (_info['complete'] == true)
          Text('Terbaca utuh: seluruh tensor ada di berkas (${_fmtBytes(dataBytes)} data).', style: const TextStyle(color: green, fontSize: 12))
        else ...[
          const Text('Perlu perhatian:', style: TextStyle(color: errorRed, fontSize: 12, fontWeight: FontWeight.w600)),
          for (final i in issues) Text('• $i', style: const TextStyle(color: errorRed, fontSize: 12)),
        ],
        const SizedBox(height: 6),
        const Text('Perubahan disimpan sebagai salinan baru; model asli tetap utuh dan butuh ruang kosong sebesar model.',
            style: TextStyle(color: muted, fontSize: 11, height: 1.4)),
      ]),
    );
  }

  Widget _tensorSection() {
    final total = (_info['tensorCount'] as num?)?.toInt() ?? 0;
    return Container(
      decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(10), border: Border.all(color: line)),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: ValueKey('tensors:$_path'),
          title: Text('Tensor (${_fmtCount(total)})', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          subtitle: const Text('Nama, bentuk, tipe kuantisasi, dan ukuran tiap tensor', style: TextStyle(color: muted, fontSize: 11)),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          onExpansionChanged: (open) {
            if (open && _tensors.isEmpty && !_tensorsLoading) _loadTensors(reset: true);
          },
          children: [
            TextField(
              controller: _tensorSearch,
              onChanged: _onTensorQuery,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 18), hintText: 'Cari nama tensor (mis. blk.3, attn, token_embd)', isDense: true),
            ),
            const SizedBox(height: 8),
            for (final t in _tensors) _tensorRow(t),
            if (_tensorError != null)
              Padding(padding: const EdgeInsets.only(top: 6), child: Text(_tensorError!, style: const TextStyle(color: errorRed, fontSize: 12))),
            if (_tensorsLoading) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(minHeight: 2)),
            if (!_tensorsLoading && _tensorError == null && _tensors.isEmpty)
              const Padding(padding: EdgeInsets.only(top: 6), child: Text('Tidak ada tensor yang cocok.', style: TextStyle(color: muted, fontSize: 12))),
            if (_tensors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Text('${_fmtCount(_tensors.length)} dari ${_fmtCount(_tensorMatched)}', style: const TextStyle(color: muted, fontSize: 11)),
                  const Spacer(),
                  if (_tensors.length < _tensorMatched) TextButton(onPressed: _tensorsLoading ? null : () => _loadTensors(), child: const Text('Muat lagi')),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tensorRow(Map<String, dynamic> t) {
    final shape = ((t['shape'] as List?) ?? const []).map((e) => '$e').join(' × ');
    final bytes = (t['bytes'] as num?) ?? -1;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${t['name']}', style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
        Text('${t['type']} · [$shape] · ${bytes < 0 ? 'ukuran tidak diketahui' : _fmtBytes(bytes)}', style: const TextStyle(color: muted, fontSize: 11)),
      ]),
    );
  }

  Widget _row(Map<String, dynamic> e) {
    final key = e['key'] as String;
    final p = _pending[key];
    final deleted = p?['delete'] == true;
    final changed = p != null;
    final value = p != null && !deleted ? '${p['value']}' : (e['value'] as String?);
    final isArray = e['type'] == 'array';
    final editable = e['editable'] == true;
    final preview = isArray ? '[${e['elemType']} × ${e['count']}]' : (value ?? '—');
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: changed ? const Color(0xFF2A2740) : panel,
      child: ListTile(
        dense: true,
        onTap: _saving ? null : () => (e['viewable'] == true ? _viewArray(e) : _editEntry(e)),
        title: Text(key, style: TextStyle(fontSize: 13, decoration: deleted ? TextDecoration.lineThrough : null)),
        subtitle: Text(
          deleted ? 'akan dihapus' : '${e['type']} · ${preview.replaceAll('\n', ' ')}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: deleted ? errorRed : muted, fontSize: 12, fontFamily: 'monospace'),
        ),
        trailing: changed
            ? const Icon(Icons.circle, size: 10, color: amber)
            : Icon(e['viewable'] == true ? Icons.visibility_outlined : (editable ? Icons.edit_outlined : Icons.lock_outline), size: 16, color: muted),
      ),
    );
  }
}

/// Penampil isi array metadata (mis. daftar token) per halaman, tanpa memuat seluruh array ke memori.
class _ArrayViewerDialog extends StatefulWidget {
  const _ArrayViewerDialog({required this.path, required this.keyName, required this.elemType, required this.count});
  final String path;
  final String keyName;
  final String elemType;
  final int count;

  @override
  State<_ArrayViewerDialog> createState() => _ArrayViewerDialogState();
}

class _ArrayViewerDialogState extends State<_ArrayViewerDialog> {
  static const _page = 100;
  final _jump = TextEditingController();
  int _offset = 0;
  List<String> _items = const [];
  bool _loading = true;
  String? _error;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _jump.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final req = ++_req;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Bridge.ggufArray(widget.path, widget.keyName, offset: _offset, limit: _page);
      if (!mounted || req != _req) return;
      setState(() {
        _offset = (r['offset'] as num?)?.toInt() ?? _offset;
        _items = ((r['items'] as List?) ?? const []).map((e) => '$e').toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted || req != _req) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  void _go(int offset) {
    final last = widget.count <= 0 ? 0 : ((widget.count - 1) ~/ _page) * _page;
    _offset = offset.clamp(0, last);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final end = _offset + _items.length;
    return AlertDialog(
      title: Text(widget.keyName, style: const TextStyle(fontSize: 14)),
      content: SizedBox(
        width: double.maxFinite,
        height: 440,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${widget.elemType} × ${_fmtCount(widget.count)} · hanya bisa dibaca', style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 6),
          Expanded(
            child: _error != null
                ? Text(_error!, style: const TextStyle(color: errorRed, fontSize: 12))
                : _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: _items.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text('${_offset + i}  ${_items[i].replaceAll('\n', r'\n').replaceAll('\r', r'\r').replaceAll('\t', r'\t')}',
                              style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                        ),
                      ),
          ),
          const SizedBox(height: 6),
          Row(children: [
            IconButton(tooltip: 'Sebelumnya', onPressed: _loading || _offset == 0 ? null : () => _go(_offset - _page), icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: Text(widget.count == 0 ? 'Kosong' : '${_offset + 1}–$end dari ${_fmtCount(widget.count)}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
            ),
            IconButton(tooltip: 'Berikutnya', onPressed: _loading || end >= widget.count ? null : () => _go(_offset + _page), icon: const Icon(Icons.chevron_right)),
          ]),
          TextField(
            controller: _jump,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: 'Ke indeks…', isDense: true),
            onSubmitted: (v) {
              final n = int.tryParse(v.trim());
              if (n != null) _go((n ~/ _page) * _page);
            },
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup'))],
    );
  }
}
