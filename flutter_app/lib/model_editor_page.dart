import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bridge.dart';
import 'gguf_editor.dart';
import 'lora_page.dart';
import 'model_params_tab.dart';
import 'privacy_editor.dart';
import 'theme.dart';
import 'tokenizer_tab.dart';
import 'weight_ops_page.dart';

String _err(Object e) => e is PlatformException ? (e.message ?? e.code) : '$e';

String _size(num n) {
  if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(2)} GB';
  if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(0)} MB';
  return '${(n / 1e3).toStringAsFixed(0)} KB';
}

enum ModelEditTab { info, metadata, tokenizer, params, privacy, lora, weights, manage }

String _tabLabel(ModelEditTab t) => switch (t) {
      ModelEditTab.info => 'Info',
      ModelEditTab.metadata => 'Metadata & template',
      ModelEditTab.tokenizer => 'Tokenizer',
      ModelEditTab.params => 'Parameter model',
      ModelEditTab.privacy => 'Privasi',
      ModelEditTab.lora => 'LoRA',
      ModelEditTab.weights => 'Bobot (server)',
      ModelEditTab.manage => 'Kelola',
    };

/// Satu pintu untuk semua pengeditan model: pemilih model di atas, tab per area di bawahnya.
/// Saat belum ada model, halaman menawarkan tombol ke Library dan Import.
class ModelEditorPage extends StatefulWidget {
  const ModelEditorPage({
    super.key,
    required this.onLog,
    this.initialPath,
    this.initialTab = ModelEditTab.info,
    this.onOpenLibrary,
    this.onOpenImport,
    this.onGuardrailChanged,
  });

  final void Function(String level, String message) onLog;
  final String? initialPath;
  final ModelEditTab initialTab;
  final VoidCallback? onOpenLibrary;
  final VoidCallback? onOpenImport;
  final VoidCallback? onGuardrailChanged;

  @override
  State<ModelEditorPage> createState() => _ModelEditorPageState();
}

class _ModelEditorPageState extends State<ModelEditorPage> {
  List<Map<String, dynamic>> _models = [];
  String? _path;
  late ModelEditTab _tab = widget.initialTab;
  bool _loading = true;
  String _error = '';

  // Tab Info
  Map<String, dynamic> _info = const {};
  Map<String, dynamic> _health = const {};
  bool _infoLoading = false;
  String _infoError = '';

  // Tab Kelola
  bool _manageBusy = false;
  String _manageStatus = '';

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  Map<String, dynamic>? get _current {
    for (final m in _models) {
      if (m['path'] == _path) return m;
    }
    return null;
  }

  Future<void> _loadModels() async {
    try {
      final list = await Bridge.localModels(hash: false);
      if (!mounted) return;
      setState(() {
        _models = list;
        final want = widget.initialPath;
        if (_path == null || !list.any((m) => m['path'] == _path)) {
          if (want != null && list.any((m) => m['path'] == want)) {
            _path = want;
          } else if (list.isNotEmpty) {
            _path = '${(list.firstWhere((m) => m['active'] == true, orElse: () => list.first))['path']}';
          } else {
            _path = null;
          }
        }
        _loading = false;
        _error = '';
      });
      if (_path != null) _loadInfo();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Gagal memuat daftar model: ${_err(e)}';
        });
      }
    }
  }

  Future<void> _loadInfo() async {
    final p = _path;
    if (p == null) return;
    setState(() {
      _infoLoading = true;
      _infoError = '';
    });
    try {
      final info = await Bridge.ggufInspect(p);
      Map<String, dynamic> health = const {};
      try {
        health = await Bridge.deviceHealth(modelSize: ((info['size'] as num?) ?? 0).toInt());
      } catch (_) {}
      if (!mounted || p != _path) return;
      setState(() {
        _info = info;
        _health = health;
        _infoLoading = false;
      });
    } catch (e) {
      if (mounted && p == _path) {
        setState(() {
          _infoLoading = false;
          _infoError = 'Gagal membaca model: ${_err(e)}';
        });
      }
    }
  }

  void _pick(String? v) {
    if (v == null || v == _path) return;
    setState(() {
      _path = v;
      _info = const {};
      _manageStatus = '';
    });
    _loadInfo();
  }

  // ---- kosong ----

  Widget _empty() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(14), border: Border.all(color: line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.memory_outlined, color: muted),
            SizedBox(width: 8),
            Text('Belum ada model lokal', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          const Text(
            'Semua editor di sini bekerja pada model GGUF yang terpasang di perangkat. Unduh model dari Library atau impor berkas GGUF, lalu kembali ke sini.',
            style: TextStyle(color: muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: widget.onOpenLibrary,
              icon: const Icon(Icons.library_books_outlined, size: 18),
              label: const Text('Buka Library'),
            ),
            OutlinedButton.icon(
              onPressed: widget.onOpenImport,
              icon: const Icon(Icons.file_upload_outlined, size: 18),
              label: const Text('Impor GGUF'),
            ),
          ]),
        ]),
      );

  // ---- tab Info ----

  Widget _kv(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(k, style: const TextStyle(color: muted, fontSize: 12))),
          Expanded(child: SelectableText(v, style: TextStyle(fontSize: 12, color: color))),
        ]),
      );

  /// Estimasi RAM = ukuran berkas x 1,25 (angka yang sama dengan daftar model). Hijau bila muat
  /// dengan lega, kuning bila mepet, merah bila melebihi RAM yang tersedia.
  (Color, String) _ramVerdict(num need) {
    final total = (_health['totalRam'] as num?) ?? 0;
    final avail = (_health['availableRam'] as num?) ?? 0;
    if (total <= 0) return (muted, 'RAM perangkat tidak diketahui');
    if (need > avail) return (errorRed, 'Melebihi RAM tersedia (${_size(avail)} dari ${_size(total)})');
    if (need > avail * 0.7) return (amber, 'Mepet: butuh ${_size(need)}, tersedia ${_size(avail)}');
    return (green, 'Cukup: butuh ${_size(need)}, tersedia ${_size(avail)}');
  }

  Widget _infoTab() {
    final m = _current;
    if (m == null) return const SizedBox.shrink();
    if (_infoLoading && _info.isEmpty) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
    if (_infoError.isNotEmpty) return Text(_infoError, style: const TextStyle(color: errorRed, fontSize: 12));
    final issues = ((_info['issues'] as List?) ?? const []).map((e) => '$e').toList();
    final complete = _info['complete'] == true;
    final size = (m['size'] as num?) ?? 0;
    final need = (m['ramRecommended'] as num?) ?? (size * 1.25);
    final (ramColor, ramText) = _ramVerdict(need);
    final params = _info['params'] as num?;
    final repo = '${m['sourceRepo'] ?? ''}';
    final rev = '${m['sourceRevision'] ?? ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _kv('Berkas', '${m['name']}'),
      _kv('Ukuran', _size(size)),
      _kv('Kuantisasi', '${_info['fileTypeName'] ?? '-'}'),
      _kv('Parameter', params == null ? '-' : (params >= 1e9 ? '${(params / 1e9).toStringAsFixed(2)} miliar' : '${(params / 1e6).toStringAsFixed(0)} juta')),
      _kv('Layer', '${_info['layers'] ?? '-'}'),
      _kv('Tensor / token', '${_info['tensorCount'] ?? '-'} / ${(_info['tokenCount'] as num?) == null || (_info['tokenCount'] as num) < 0 ? '-' : _info['tokenCount']}'),
      _kv('Repo asal', repo.isEmpty ? 'tidak tercatat (diimpor manual)' : repo),
      if (rev.isNotEmpty) _kv('Revision', rev),
      _kv('Status', m['active'] == true ? 'Aktif' : 'Terpasang, belum aktif'),
      _kv('Estimasi RAM', ramText, color: ramColor),
      const SizedBox(height: 8),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(border: Border.all(color: complete ? green : amber), borderRadius: BorderRadius.circular(8)),
        child: complete
            ? const Text('Pemeriksaan integritas lolos: data tensor lengkap, sejajar, dan tidak tumpang tindih.', style: TextStyle(color: green, fontSize: 12))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Berkas mungkin terpotong atau rusak (unduhan belum lengkap?)', style: TextStyle(color: amber, fontSize: 12)),
                for (final i in issues) Text('• $i', style: const TextStyle(color: muted, fontSize: 11)),
              ]),
      ),
      const SizedBox(height: 6),
      const Text('Struktur tensor lengkap dan edit metadata ada di tab "Metadata & template".', style: TextStyle(color: muted, fontSize: 11)),
    ]);
  }

  // ---- tab Kelola ----

  Future<void> _manage(Future<String> Function() task) async {
    if (_manageBusy) return;
    setState(() {
      _manageBusy = true;
      _manageStatus = '';
    });
    try {
      final msg = await task();
      if (mounted) setState(() => _manageStatus = msg);
    } catch (e) {
      if (mounted) setState(() => _manageStatus = 'Gagal: ${_err(e)}');
      widget.onLog('ERROR', 'Kelola model: ${_err(e)}');
    }
    if (mounted) setState(() => _manageBusy = false);
  }

  Widget _manageTab() {
    final m = _current;
    if (m == null) return const SizedBox.shrink();
    final path = '${m['path']}';
    final active = m['active'] == true;
    final copies = _models.where((x) => '${x['name']}'.contains('-edited-')).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(
          onPressed: _manageBusy
              ? null
              : () => _manage(() async {
                    final r = await Bridge.verifyLocalModel(path);
                    return 'SHA-256: ${r['sha256']}\nUkuran: ${_size((r['size'] as num?) ?? 0)}';
                  }),
          child: const Text('Verifikasi SHA-256'),
        ),
        OutlinedButton(
          onPressed: (_manageBusy || active)
              ? null
              : () => _manage(() async {
                    await Bridge.activateLocalModel(path);
                    await _loadModels();
                    widget.onLog('INFO', 'Model diaktifkan: ${m['name']}');
                    return 'Model diaktifkan.';
                  }),
          child: const Text('Jadikan aktif'),
        ),
        OutlinedButton(
          onPressed: _manageBusy
              ? null
              : () => _manage(() async {
                    final r = await Bridge.exportLocalModelMetadata(path);
                    await Clipboard.setData(ClipboardData(text: r.entries.map((e) => '${e.key}: ${e.value}').join('\n')));
                    return 'Ringkasan metadata disalin ke papan klip.';
                  }),
          child: const Text('Salin ringkasan'),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: errorRed, side: const BorderSide(color: errorRed)),
          onPressed: (_manageBusy || active) ? null : () => _deleteModel(path, '${m['name']}'),
          child: const Text('Hapus'),
        ),
      ]),
      if (active)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Model aktif tidak bisa dihapus. Aktifkan model lain dulu.', style: TextStyle(color: muted, fontSize: 11)),
        ),
      const SizedBox(height: 14),
      const Text('SALINAN HASIL EDIT', style: TextStyle(color: muted, fontSize: 9, letterSpacing: 1.1)),
      const SizedBox(height: 4),
      if (copies.isEmpty)
        const Text('Belum ada salinan hasil edit (<nama>-edited-<waktu>.gguf).', style: TextStyle(color: muted, fontSize: 11))
      else
        for (final c in copies)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${c['name']}', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
            subtitle: Text(_size((c['size'] as num?) ?? 0), style: const TextStyle(color: muted, fontSize: 10)),
            trailing: IconButton(
              icon: const Icon(Icons.open_in_new, size: 18),
              tooltip: 'Pilih salinan ini',
              onPressed: () => _pick('${c['path']}'),
            ),
          ),
      const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text('Hapus salinan lama untuk menghemat ruang: tiap salinan seukuran model aslinya.', style: TextStyle(color: muted, fontSize: 11)),
      ),
      if (_manageStatus.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: SelectableText(_manageStatus, style: const TextStyle(fontSize: 12))),
    ]);
  }

  Future<void> _deleteModel(String path, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Hapus model?'),
        content: Text('$name akan dihapus dari perangkat. Tindakan ini tidak bisa dibatalkan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: errorRed), onPressed: () => Navigator.pop(c, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (ok != true) return;
    await _manage(() async {
      await Bridge.deleteLocalModel(path);
      widget.onLog('INFO', 'Model dihapus: $name');
      _path = null;
      await _loadModels();
      return 'Model dihapus.';
    });
  }

  // ---- isi tab ----

  Widget _body() {
    final m = _current;
    if (m == null) return const SizedBox.shrink();
    return switch (_tab) {
      ModelEditTab.info => _infoTab(),
      ModelEditTab.metadata => GgufEditorPage(key: ValueKey('gguf_$_path'), onLog: widget.onLog, initialPath: _path),
      ModelEditTab.tokenizer => TokenizerPanel(key: ValueKey('tok_$_path'), path: _path!, onLog: widget.onLog),
      ModelEditTab.params => ModelParamsPanel(key: ValueKey('par_$_path'), path: _path!, isActive: m['active'] == true, onLog: widget.onLog),
      ModelEditTab.privacy => PrivacyEditorPanel(
          key: ValueKey('priv_$_path'),
          path: _path!,
          isActive: m['active'] == true,
          onLog: widget.onLog,
          onGuardrailChanged: widget.onGuardrailChanged,
        ),
      ModelEditTab.lora => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (m['active'] != true)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('LoRA dipasang pada model aktif. Aktifkan model ini di tab Kelola dulu.', style: TextStyle(color: amber, fontSize: 11)),
            ),
          LoraPage(onLog: widget.onLog),
        ]),
      ModelEditTab.weights => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Membutuhkan server: kuantisasi, tanam LoRA, dan gabung model berjalan di server HTTPS, bukan di HP.', style: TextStyle(color: amber, fontSize: 11)),
          ),
          WeightOpsPage(onLog: widget.onLog),
        ]),
      ModelEditTab.manage => _manageTab(),
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Edit model', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text('Info, metadata, template chat, privasi, LoRA, dan pengelolaan model di satu tempat.', style: TextStyle(color: muted, fontSize: 12)),
      const SizedBox(height: 12),
      if (_error.isNotEmpty) Text(_error, style: const TextStyle(color: errorRed, fontSize: 12)),
      if (_models.isEmpty)
        _empty()
      else ...[
        DropdownButtonFormField<String>(
          isExpanded: true,
          value: _path,
          decoration: const InputDecoration(labelText: 'Model yang diedit'),
          items: [
            for (final m in _models)
              DropdownMenuItem<String>(
                value: '${m['path']}',
                child: Text('${m['name']}${m['active'] == true ? '  • aktif' : ''}', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _pick,
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final t in ModelEditTab.values)
            ChoiceChip(
              label: Text(_tabLabel(t), style: const TextStyle(fontSize: 12)),
              selected: _tab == t,
              onSelected: (_) => setState(() => _tab = t),
            ),
        ]),
        const SizedBox(height: 12),
        _body(),
      ],
    ]);
  }
}
