import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'bridge.dart';
import 'errors.dart';
import 'theme.dart';

String _fmtSize(num n) {
  if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(2)} GB';
  if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(1)} MB';
  return '${(n / 1e3).toStringAsFixed(0)} KB';
}

List<String> _strings(Object? v) => (v as List?)?.map((e) => '$e').toList() ?? const <String>[];

/// Memasang atau melepas adapter LoRA pada model aktif, mengatur skalanya, dan mengujinya langsung (A/B).
/// Pergantian adapter berlaku seketika pada model yang sudah dimuat, tanpa memuat ulang model.
class LoraPage extends StatefulWidget {
  const LoraPage({super.key, required this.onLog});
  final void Function(String level, String message) onLog;

  @override
  State<LoraPage> createState() => _LoraPageState();
}

class _LoraPageState extends State<LoraPage> {
  final _prompt = TextEditingController();
  bool _busy = false;
  bool _testing = false;
  String _status = '';
  Map<String, dynamic> _state = const {};
  List<Map<String, dynamic>> _adapters = const [];
  double _scale = 1;
  int _maxTokens = 128;
  Map<String, dynamic>? _ab;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final state = await Bridge.loraState();
      final list = await Bridge.loraList();
      if (!mounted) return;
      final notes = _strings(list['notes']);
      setState(() {
        _state = state;
        _adapters = ((list['adapters'] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        _scale = (state['scale'] as num?)?.toDouble() ?? 1;
        if (notes.isNotEmpty) _status = notes.join('\n');
      });
    } catch (e) {
      if (mounted) setState(() => _status = friendlyError(e));
    }
  }

  Future<void> _run(Future<void> Function() job) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      widget.onLog('ERROR', 'LoRA: ${friendlyError(e)}');
      if (mounted) setState(() => _status = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() => _run(() async {
        final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['gguf'], withData: false);
        final path = picked?.files.single.path;
        if (path == null) return;
        final r = await Bridge.loraImport(path);
        widget.onLog('INFO', 'Adapter LoRA diimpor: ${r['name']}');
        await _load();
        if (mounted) setState(() => _status = 'Adapter diimpor: ${r['name']}. Tekan Pasang untuk memakainya.');
      });

  Future<void> _attach(Map<String, dynamic> a) => _run(() async {
        final r = await Bridge.loraAttach('${a['path']}', _scale);
        widget.onLog('INFO', 'Adapter LoRA dipasang: ${a['name']} (skala ${_scale.toStringAsFixed(2)})');
        await _load();
        final warnings = _strings(r['warnings']);
        if (!mounted) return;
        setState(() => _status = [
              r['hot'] == true ? 'Adapter dipasang dan langsung aktif di model yang sedang dimuat.' : 'Adapter dipasang. Aktif saat model dimuat berikutnya.',
              ...warnings,
            ].join('\n'));
      });

  Future<void> _detach() => _run(() async {
        final r = await Bridge.loraDetach();
        widget.onLog('INFO', 'Adapter LoRA dilepas');
        await _load();
        if (mounted) setState(() => _status = r['hot'] == true ? 'Adapter dilepas dari model yang sedang dimuat.' : 'Adapter dilepas.');
      });

  Future<void> _commitScale(double v) => _run(() async {
        await Bridge.loraSetScale(v);
        widget.onLog('INFO', 'Skala LoRA diubah ke ${v.toStringAsFixed(2)}');
        await _load();
      });

  Future<void> _delete(Map<String, dynamic> a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        title: const Text('Hapus adapter?'),
        content: Text('${a['name']} (${_fmtSize((a['size'] as num?) ?? 0)}) akan dihapus dari perangkat.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await Bridge.loraDelete('${a['path']}');
      widget.onLog('INFO', 'Adapter LoRA dihapus: ${a['name']}');
      await _load();
    });
  }

  Future<void> _unloadModel() => _run(() async {
        await Bridge.unloadModel();
        await _load();
        if (mounted) setState(() => _status = 'Model dilepas dari memori. RAM adapter ikut bebas.');
      });

  Future<void> _runAb() async {
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) {
      setState(() => _status = 'Tulis prompt uji dulu.');
      return;
    }
    if (_busy || _testing) return;
    setState(() {
      _testing = true;
      _busy = true;
      _ab = null;
      _status = 'Menjalankan prompt tanpa adapter, lalu dengan adapter. Model dimuat dulu bila belum ada di memori.';
    });
    try {
      final r = await Bridge.loraAbTest(prompt, maxTokens: _maxTokens);
      widget.onLog('INFO', 'Uji A/B LoRA selesai');
      if (!mounted) return;
      setState(() {
        _ab = r;
        _status = '';
      });
      await _load();
    } catch (e) {
      widget.onLog('ERROR', 'Uji A/B LoRA gagal: ${friendlyError(e)}');
      if (mounted) setState(() => _status = friendlyError(e));
    } finally {
      if (mounted) {
        setState(() {
          _testing = false;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final attached = '${_state['loraPath'] ?? ''}'.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_busy) const LinearProgressIndicator(minHeight: 2),
      _statusCard(attached),
      const SizedBox(height: 10),
      _listCard(),
      const SizedBox(height: 10),
      _testCard(attached),
      if (_status.isNotEmpty)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(9)),
          child: SelectableText(_status, style: const TextStyle(fontSize: 11, height: 1.4)),
        ),
    ]);
  }

  Widget _card(String title, String detail, {Widget? child, IconData? icon}) => Card(
        color: panel,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, color: purple), const SizedBox(width: 9)],
              Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
            ]),
            const SizedBox(height: 8),
            Text(detail, style: const TextStyle(color: muted, height: 1.4, fontSize: 12)),
            if (child != null) ...[const SizedBox(height: 14), child],
          ]),
        ),
      );

  Widget _statusCard(bool attached) {
    final model = '${_state['modelName'] ?? ''}';
    final loaded = _state['engineLoaded'] == true;
    final live = '${_state['engineLoraPath'] ?? ''}';
    final configured = '${_state['loraPath'] ?? ''}';
    final inSync = live == configured;
    final String liveText;
    if (!loaded) {
      liveText = attached ? 'Model belum dimuat. Adapter dipasang otomatis saat model dimuat.' : 'Model belum dimuat.';
    } else if (inSync) {
      liveText = attached ? 'Aktif di model yang sedang dimuat.' : 'Model dimuat tanpa adapter.';
    } else {
      liveText = 'Model dimuat, tetapi adapter belum sinkron. Akan diperbaiki pada permintaan berikutnya.';
    }
    return _card(
      'Adapter terpasang',
      model.isEmpty ? 'Belum ada model dasar. Pilih dulu di Model lokal.' : 'Model dasar: $model${_state['modelArch'] != null ? ' · ${_state['modelArch']}' : ''}',
      icon: Icons.layers_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(attached ? '${_state['loraName']}' : 'Tidak ada adapter',
            style: TextStyle(fontWeight: FontWeight.w600, color: attached ? green : muted)),
        const SizedBox(height: 4),
        Text(liveText, style: const TextStyle(color: muted, fontSize: 12)),
        if (attached) ...[
          const SizedBox(height: 10),
          Text('Skala: ${_scale.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12)),
          Slider(
            value: _scale.clamp(0.0, 2.0).toDouble(),   // skala >2 (lewat lora.json) tetap tampil di teks, slider tidak boleh keluar rentang
            min: 0,
            max: 2,
            divisions: 40,
            label: _scale.toStringAsFixed(2),
            onChanged: _busy ? null : (v) => setState(() => _scale = v),
            onChangeEnd: _busy ? null : _commitScale,
          ),
          const Text('1.00 = kekuatan penuh seperti saat dilatih. 0 = sama dengan tanpa adapter. Di atas 1 memperkuat efeknya dan bisa merusak jawaban.',
              style: TextStyle(color: muted, fontSize: 11, height: 1.4)),
        ],
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (attached) OutlinedButton.icon(onPressed: _busy ? null : _detach, icon: const Icon(Icons.link_off), label: const Text('Lepas adapter')),
          if (loaded) OutlinedButton.icon(onPressed: _busy ? null : _unloadModel, icon: const Icon(Icons.memory_outlined), label: const Text('Lepas model dari RAM')),
        ]),
      ]),
    );
  }

  Widget _listCard() => _card(
        'Adapter di perangkat',
        'Adapter LoRA berformat GGUF. Hanya adapter yang dilatih dari model dasar yang sama dengan model aktif yang bisa dipasang.',
        icon: Icons.folder_open_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final a in _adapters) _adapterTile(a),
          if (_adapters.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text('Belum ada adapter. Impor berkas .gguf, atau unduh hasil training dari halaman Latih.', style: TextStyle(color: muted, fontSize: 12)),
            ),
          FilledButton.icon(onPressed: _busy ? null : _import, icon: const Icon(Icons.file_open_outlined), label: const Text('Impor adapter .gguf')),
        ]),
      );

  Widget _adapterTile(Map<String, dynamic> a) {
    final active = a['active'] == true;
    final valid = a['valid'] == true;
    final ok = a['compatible'] == true;
    final problems = _strings(a['problems']);
    final warnings = _strings(a['warnings']);
    final meta = [
      _fmtSize((a['size'] as num?) ?? 0),
      if (valid && a['arch'] != null) '${a['arch']}',
      if (valid && a['alpha'] != null) 'alpha ${(a['alpha'] as num).toStringAsFixed(0)}',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: active ? green : line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('${a['name']}', style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          if (active) const Text('TERPASANG', style: TextStyle(color: green, fontSize: 10, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 3),
        Text(meta, style: const TextStyle(color: muted, fontSize: 11)),
        if (valid && a['baseModel'] != null)
          Text('Dilatih dari: ${a['baseModel']}', style: const TextStyle(color: muted, fontSize: 11)),
        for (final p in problems) Padding(padding: const EdgeInsets.only(top: 6), child: Text(p, style: const TextStyle(color: errorRed, fontSize: 11, height: 1.35))),
        for (final w in warnings) Padding(padding: const EdgeInsets.only(top: 6), child: Text(w, style: const TextStyle(color: amber, fontSize: 11, height: 1.35))),
        if (ok && warnings.isEmpty) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Cocok dengan model aktif', style: TextStyle(color: green, fontSize: 11))),
        const SizedBox(height: 8),
        Row(children: [
          if (!active) FilledButton.tonal(onPressed: _busy || !ok ? null : () => _attach(a), child: const Text('Pasang')),
          const Spacer(),
          IconButton(
            tooltip: active ? 'Lepas dulu sebelum menghapus' : 'Hapus',
            onPressed: _busy || active ? null : () => _delete(a),
            icon: const Icon(Icons.delete_outline),
          ),
        ]),
      ]),
    );
  }

  Widget _testCard(bool attached) => _card(
        'Uji langsung (A/B)',
        'Satu prompt dijalankan dua kali: tanpa adapter, lalu dengan adapter. Memakai temperature 0 supaya perbedaannya berasal dari adapter, bukan dari acak.',
        icon: Icons.science_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _prompt,
            minLines: 2,
            maxLines: 5,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Prompt uji', hintText: 'Pertanyaan yang ingin dibandingkan jawabannya'),
          ),
          const SizedBox(height: 10),
          Row(children: [
            const Text('Maks token', style: TextStyle(fontSize: 12, color: muted)),
            const SizedBox(width: 10),
            for (final n in const [64, 128, 256])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(label: Text('$n'), selected: _maxTokens == n, onSelected: _busy ? null : (_) => setState(() => _maxTokens = n)),
              ),
          ]),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy || !attached ? null : _runAb,
            icon: _testing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
            label: Text(attached ? 'Jalankan uji A/B' : 'Pasang adapter dulu'),
          ),
          if (_ab != null) ..._abResult(_ab!),
        ]),
      );

  List<Widget> _abResult(Map<String, dynamic> r) {
    Map<String, dynamic> side(String k) => Map<String, dynamic>.from((r[k] as Map?) ?? const {});
    Widget box(String title, Map<String, dynamic> s, Color accent) {
      final text = '${s['text'] ?? ''}'.trim();
      return Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(10), border: Border.all(color: accent.withOpacity(0.5))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(color: accent, fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(height: 2),
          Text('${s['tokens'] ?? 0} token · ${s['tps'] ?? 0} token/detik', style: const TextStyle(color: muted, fontSize: 11)),
          const SizedBox(height: 8),
          SelectableText(text.isEmpty ? '(tidak ada keluaran)' : text, style: const TextStyle(fontSize: 13, height: 1.4)),
        ]),
      );
    }

    return [
      box('Tanpa adapter', side('base'), muted),
      box('Dengan ${r['adapterName'] ?? 'adapter'} (skala ${r['scale'] ?? 1})', side('adapter'), green),
      if (r['same'] == true)
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text('Jawaban identik. Adapter mungkin tidak berpengaruh pada prompt ini, atau skalanya terlalu kecil. Coba prompt yang sesuai data latihnya.',
              style: TextStyle(color: amber, fontSize: 11, height: 1.4)),
        ),
    ];
  }
}
