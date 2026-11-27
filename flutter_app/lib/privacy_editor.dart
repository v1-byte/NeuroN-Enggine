import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bridge.dart';
import 'privacy_logic.dart';
import 'theme.dart';

String _err(Object e) => e is PlatformException ? (e.message ?? e.code) : '$e';

/// Editor privasi tertanam (tab "Privasi" di layar Edit model) untuk satu model [path].
///
/// Dua tampilan atas berkas yang sama: Daftar (kata dan regex per item, bisa ditambah/diubah/dihapus)
/// dan JSON (teks mentah). Ada kolom uji, pratinjau hasil baca, validasi regex, ekspor/impor,
/// dan tombol kembali ke versi repo asal.
class PrivacyEditorPanel extends StatefulWidget {
  const PrivacyEditorPanel({
    super.key,
    required this.path,
    required this.isActive,
    required this.onLog,
    this.onGuardrailChanged,
  });

  final String path;
  final bool isActive;
  final void Function(String level, String message) onLog;
  final VoidCallback? onGuardrailChanged;

  @override
  State<PrivacyEditorPanel> createState() => _PrivacyEditorPanelState();
}

class _PrivacyEditorPanelState extends State<PrivacyEditorPanel> {
  final _text = TextEditingController();
  final _sample = TextEditingController();
  final _newItem = TextEditingController();
  bool _jsonMode = false;
  bool _busy = false;
  bool _dirty = false;
  bool _exists = false;
  String _status = '';
  String _source = '';
  String _file = '';
  String _newKind = 'kata';
  PrivacyPreview _preview = const PrivacyPreview(error: 'privacy.json kosong');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PrivacyEditorPanel old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _load();
  }

  @override
  void dispose() {
    _text.dispose();
    _sample.dispose();
    _newItem.dispose();
    super.dispose();
  }

  void _setText(String t, {bool dirty = true}) {
    _text.text = t;
    _preview = previewPrivacy(t);
    _dirty = dirty;
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final r = await Bridge.privacyLoad(widget.path);
      if (!mounted) return;
      setState(() {
        _setText(r['text'] as String? ?? '', dirty: false);
        _exists = r['exists'] == true;
        _source = r['source'] as String? ?? '';
        _file = r['file'] as String? ?? '';
        _status = _exists
            ? 'Salinan lokal dimuat.'
            : 'Belum ada salinan untuk model ini. Tekan "Ambil dari repo asal".';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Gagal memuat: ${_err(e)}');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _fetch() async {
    if (_dirty && !await _confirm('Ganti isi dengan versi repo?', 'Perubahan yang belum disimpan akan hilang.')) return;
    setState(() => _busy = true);
    try {
      final r = await Bridge.privacyFetch(widget.path);
      if (!mounted) return;
      setState(() {
        _setText(r['text'] as String? ?? '');
        _status = 'Diambil dari ${r['source']}. Tinjau lalu simpan.';
      });
      widget.onLog('INFO', 'privacy.json diambil dari ${r['source']}');
    } catch (e) {
      if (mounted) setState(() => _status = 'Gagal mengambil: ${_err(e)}');
      widget.onLog('ERROR', 'Gagal mengambil privacy.json: ${_err(e)}');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lanjut')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _save(bool use) async {
    if (!_preview.ok) {
      setState(() => _status = 'Tidak bisa menyimpan: ${_preview.error}');
      return;
    }
    if (_preview.invalidRegex.isNotEmpty &&
        !await _confirm('Ada regex tidak valid', '${_preview.invalidRegex.length} pola akan dilewati saat dipakai. Tetap simpan?')) {
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await Bridge.privacyApply(widget.path, _text.text, use: use);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _exists = true;
        _status = r.used
            ? 'Disimpan ke ${r.file} dan dipakai. Guardrail kini berisi ${r.words.length} kata dan ${r.regex.length} regex.'
            : 'Disimpan ke ${r.file}. Belum dipakai di guardrail.';
        if (r.warnings.isNotEmpty) _status += '\n${r.warnings.join('\n')}';
      });
      widget.onLog('INFO', _status.split('\n').first);
      for (final w in r.warnings) {
        widget.onLog('WARN', w);
      }
      if (r.used) widget.onGuardrailChanged?.call();
    } catch (e) {
      if (mounted) setState(() => _status = 'Gagal: ${_err(e)}');
      widget.onLog('ERROR', 'Gagal menyimpan privasi: ${_err(e)}');
    }
    if (mounted) setState(() => _busy = false);
  }

  // ---- daftar item ----

  /// Menulis daftar ke JSON hanya aman bila berkas sudah berskema terdokumentasi,
  /// atau pengguna setuju menggantinya dengan skema itu.
  Future<void> _writeLists(List<String> words, List<String> regex) async {
    if (_text.text.trim().isNotEmpty && !isDocumentedShape(_text.text)) {
      final ok = await _confirm('Ubah ke skema standar?',
          'Berkas ini memakai kunci selain "blocked_terms" dan "regex". Mengubah lewat daftar akan menulis ulang berkas ke skema standar dan membuang kunci lain. Lanjut?');
      if (!ok) return;
    }
    if (!mounted) return;
    setState(() => _setText(buildPrivacyJson(words, regex)));
  }

  Future<void> _addItem() async {
    final v = _newItem.text.trim();
    if (v.isEmpty) return;
    final words = [..._preview.words];
    final regex = [..._preview.regex, ..._preview.invalidRegex];
    if (_newKind == 'regex') {
      if (!isValidRegex(v)) {
        setState(() => _status = 'Regex tidak valid, tidak ditambahkan.');
        return;
      }
      if (!regex.contains(v)) regex.add(v);
    } else if (!words.contains(v)) {
      words.add(v);
    }
    _newItem.clear();
    await _writeLists(words, regex);
  }

  Future<void> _removeItem(String kind, String v) async {
    final words = [..._preview.words];
    final regex = [..._preview.regex, ..._preview.invalidRegex];
    (kind == 'regex' ? regex : words).remove(v);
    await _writeLists(words, regex);
  }

  Future<void> _editItem(String kind, String old) async {
    final c = TextEditingController(text: old);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final bad = kind == 'regex' && !isValidRegex(c.text);
        return AlertDialog(
          title: Text('Ubah $kind'),
          content: TextField(
            controller: c,
            autofocus: true,
            onChanged: (_) => set(() {}),
            decoration: InputDecoration(errorText: bad ? 'Regex tidak valid' : null),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
            FilledButton(onPressed: bad ? null : () => Navigator.pop(ctx, c.text.trim()), child: const Text('Simpan')),
          ],
        );
      }),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), c.dispose);
    if (v == null || v.isEmpty || v == old) return;
    final words = [..._preview.words];
    final regex = [..._preview.regex, ..._preview.invalidRegex];
    final list = kind == 'regex' ? regex : words;
    final i = list.indexOf(old);
    if (i >= 0) list[i] = v;
    await _writeLists(words, regex);
  }

  // ---- ekspor / impor ----

  Future<void> _export() async {
    await Clipboard.setData(ClipboardData(text: _text.text));
    if (mounted) setState(() => _status = 'Isi privacy.json disalin ke papan klip.');
  }

  Future<void> _import() async {
    try {
      final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['json']);
      final p = picked?.files.single.path;
      if (p == null) return;
      final t = await File(p).readAsString();
      if (!mounted) return;
      setState(() {
        _setText(t);
        _status = 'Diimpor dari berkas. Tinjau lalu simpan.';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Gagal impor: ${_err(e)}');
    }
  }

  // ---- tampilan ----

  Widget _chipRow(String kind, String v, {bool bad = false}) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(
          color: ink,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: bad ? errorRed : line),
        ),
        child: Row(children: [
          Text(kind == 'regex' ? '.*' : 'Aa', style: const TextStyle(color: muted, fontSize: 11, fontFamily: 'monospace')),
          const SizedBox(width: 8),
          Expanded(child: Text(v, style: const TextStyle(fontFamily: 'monospace', fontSize: 12), overflow: TextOverflow.ellipsis)),
          if (bad) const Text('tidak valid', style: TextStyle(color: errorRed, fontSize: 10)),
          IconButton(
            tooltip: 'Ubah',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 16),
            onPressed: _busy ? null : () => _editItem(kind, v),
          ),
          IconButton(
            tooltip: 'Hapus',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline, size: 16),
            onPressed: _busy ? null : () => _removeItem(kind, v),
          ),
        ]),
      );

  Widget _listView() {
    final p = _preview;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        DropdownButton<String>(
          value: _newKind,
          items: const [
            DropdownMenuItem(value: 'kata', child: Text('Kata')),
            DropdownMenuItem(value: 'regex', child: Text('Regex')),
          ],
          onChanged: (v) => setState(() => _newKind = v ?? 'kata'),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _newItem,
            onSubmitted: (_) => _addItem(),
            decoration: InputDecoration(hintText: _newKind == 'regex' ? r'mis. \b\d{16}\b' : 'kata terlarang'),
          ),
        ),
        IconButton(onPressed: _busy ? null : _addItem, icon: const Icon(Icons.add_circle_outline)),
      ]),
      const SizedBox(height: 8),
      if (!p.ok)
        Text(_text.text.trim().isEmpty ? 'Belum ada isi. Tambah item di atas atau ambil dari repo asal.' : p.error!,
            style: const TextStyle(color: amber, fontSize: 11))
      else ...[
        Text('KATA TERLARANG (${p.words.length})', style: const TextStyle(color: muted, fontSize: 9, letterSpacing: 1.1)),
        const SizedBox(height: 4),
        for (final w in p.words) _chipRow('kata', w),
        const SizedBox(height: 6),
        Text('REGEX (${p.regex.length + p.invalidRegex.length})', style: const TextStyle(color: muted, fontSize: 9, letterSpacing: 1.1)),
        const SizedBox(height: 4),
        for (final r in p.regex) _chipRow('regex', r),
        for (final r in p.invalidRegex) _chipRow('regex', r, bad: true),
      ],
    ]);
  }

  Widget _jsonView() => TextField(
        controller: _text,
        enabled: !_busy,
        minLines: 8,
        maxLines: 16,
        onChanged: (t) => setState(() {
          _preview = previewPrivacy(t);
          _dirty = true;
        }),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: const InputDecoration(labelText: 'privacy.json'),
      );

  Widget _tester() {
    final hits = _sample.text.isEmpty ? const <PrivacyHit>[] : testPrivacy(_sample.text, _preview);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('UJI KALIMAT', style: TextStyle(color: muted, fontSize: 9, letterSpacing: 1.1)),
      const SizedBox(height: 4),
      TextField(
        controller: _sample,
        minLines: 1,
        maxLines: 3,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(hintText: 'Tempel kalimat untuk melihat aturan mana yang mengenainya'),
      ),
      const SizedBox(height: 4),
      if (_sample.text.isNotEmpty)
        hits.isEmpty
            ? const Text('Tidak ada aturan yang mengenai kalimat ini.', style: TextStyle(color: green, fontSize: 11))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final h in hits)
                  Text('• ${h.kind} "${h.rule}" cocok dengan "${h.match}"', style: const TextStyle(color: amber, fontSize: 11)),
              ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    final okColor = p.ok && p.warnings.isEmpty ? green : (p.ok ? amber : errorRed);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Berkas: ${_file.isEmpty ? 'privacy.json' : _file}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      Text('Sumber: ${_source.isEmpty ? '-' : _source} · Salinan lokal: ${_exists ? 'ada' : 'belum ada'}'
          '${_dirty ? '  ● belum disimpan' : ''}', style: const TextStyle(color: muted, fontSize: 11)),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        OutlinedButton(onPressed: _busy ? null : _fetch, child: const Text('Ambil dari repo asal')),
        OutlinedButton(onPressed: _busy ? null : _import, child: const Text('Impor')),
        OutlinedButton(onPressed: _busy ? null : _export, child: const Text('Ekspor (salin)')),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Daftar')),
            ButtonSegment(value: true, label: Text('JSON')),
          ],
          selected: {_jsonMode},
          onSelectionChanged: (s) => setState(() => _jsonMode = s.first),
        ),
      ]),
      const SizedBox(height: 10),
      _jsonMode ? _jsonView() : _listView(),
      const SizedBox(height: 10),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(border: Border.all(color: okColor), borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Pratinjau hasil baca: ${p.summary}', style: TextStyle(color: okColor, fontSize: 12)),
          for (final w in p.warnings) Text('• $w', style: const TextStyle(color: amber, fontSize: 11)),
        ]),
      ),
      const SizedBox(height: 10),
      _tester(),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 6, children: [
        OutlinedButton(onPressed: _busy ? null : () => _save(false), child: const Text('Simpan saja')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: blue),
          onPressed: (_busy || !widget.isActive) ? null : () => _save(true),
          child: const Text('Simpan & pakai'),
        ),
      ]),
      if (!widget.isActive)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('Untuk memakai di guardrail, aktifkan model ini dulu di Library.', style: TextStyle(color: muted, fontSize: 10)),
        ),
      if (_status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_status, style: const TextStyle(fontSize: 12))),
    ]);
  }
}
