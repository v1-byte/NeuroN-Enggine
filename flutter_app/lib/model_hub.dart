import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'bridge.dart';
import 'errors.dart';
import 'flow_stepper.dart';
import 'theme.dart';

/// Satu entri katalog. Nama file GGUF TIDAK ditulis di sini: file dipilih saat runtime
/// dari daftar file repo (lihat [_pickGguf]) sehingga tidak rusak bila penamaan repo berubah.
class CatalogModel {
  const CatalogModel({
    required this.title,
    required this.repo,
    required this.params,
    required this.approxBytes,
    required this.tag,
    required this.note,
  });
  final String title;
  final String repo;
  final String params;
  final int approxBytes; // perkiraan Q4_K_M; diganti ukuran asli setelah file ditemukan
  final String tag;
  final String note;
}

const _mb = 1024 * 1024;

/// Preset prompt sistem untuk Pengaturan model.
const kPromptPresets = <String, String>{
  'Asisten': 'Kamu asisten AI yang membantu. Jawab singkat, jelas, dan dalam bahasa yang dipakai pengguna.',
  'Penerjemah': 'Kamu penerjemah profesional. Terjemahkan teks pengguna antara bahasa Indonesia dan Inggris tanpa penjelasan tambahan.',
  'Coding': 'Kamu asisten pemrograman. Berikan kode yang benar di dalam blok kode, disertai penjelasan singkat.',
  'Ringkas': 'Kamu peringkas. Ringkas teks pengguna menjadi poin-poin padat tanpa menambah fakta baru.',
};

/// Daftar kurasi model GGUF instruct yang ringan untuk HP. Ubah di sini untuk menambah/mengganti model.
const kModelCatalog = <CatalogModel>[
  CatalogModel(
      title: 'Froged N1 (Qwen2.5 0.5B)',
      repo: 'bytecode66/Froged_N1',
      params: '0.5B',
      approxBytes: 470 * _mb,
      tag: 'Ringan',
      note: 'Model GGUF ringan dari koleksi Froged N1; cocok untuk HP dengan RAM kecil.'),
  CatalogModel(
      title: 'Qwen2.5 0.5B Instruct',
      repo: 'Qwen/Qwen2.5-0.5B-Instruct-GGUF',
      params: '0.5B',
      approxBytes: 400 * _mb,
      tag: 'Ringan',
      note: 'Tercepat, cocok untuk HP RAM kecil. Kualitas dasar.'),
  CatalogModel(
      title: 'Llama 3.2 1B Instruct',
      repo: 'bartowski/Llama-3.2-1B-Instruct-GGUF',
      params: '1B',
      approxBytes: 800 * _mb,
      tag: 'Ringan',
      note: 'Ringkas dan responsif untuk chat harian.'),
  CatalogModel(
      title: 'Qwen2.5 1.5B Instruct',
      repo: 'Qwen/Qwen2.5-1.5B-Instruct-GGUF',
      params: '1.5B',
      approxBytes: 1100 * _mb,
      tag: 'Seimbang',
      note: 'Pilihan awal yang direkomendasikan: cepat dan cukup pintar.'),
  CatalogModel(
      title: 'SmolLM2 1.7B Instruct',
      repo: 'bartowski/SmolLM2-1.7B-Instruct-GGUF',
      params: '1.7B',
      approxBytes: 1100 * _mb,
      tag: 'Seimbang',
      note: 'Model kecil yang dilatih khusus untuk perangkat terbatas.'),
  CatalogModel(
      title: 'Gemma 2 2B Instruct',
      repo: 'bartowski/gemma-2-2b-it-GGUF',
      params: '2B',
      approxBytes: 1700 * _mb,
      tag: 'Seimbang',
      note: 'Jawaban rapi untuk ukurannya.'),
  CatalogModel(
      title: 'Qwen2.5 3B Instruct',
      repo: 'Qwen/Qwen2.5-3B-Instruct-GGUF',
      params: '3B',
      approxBytes: 2100 * _mb,
      tag: 'Kuat',
      note: 'Lebih akurat, butuh RAM 6 GB ke atas.'),
  CatalogModel(
      title: 'Llama 3.2 3B Instruct',
      repo: 'bartowski/Llama-3.2-3B-Instruct-GGUF',
      params: '3B',
      approxBytes: 2000 * _mb,
      tag: 'Kuat',
      note: 'Bagus untuk instruksi dan perbaikan Copilot.'),
  CatalogModel(
      title: 'Phi-3.5 Mini Instruct',
      repo: 'bartowski/Phi-3.5-mini-instruct-GGUF',
      params: '3.8B',
      approxBytes: 2400 * _mb,
      tag: 'Kuat',
      note: 'Penalaran baik; berat untuk HP RAM 6 GB.'),
];

/// Rekomendasi model awal: yang terbesar yang masih muat di RAM, dengan batas Seimbang (1–2B) agar pengalaman pertama cepat.
/// Tanpa data RAM, ambil Qwen2.5 1.5B.
CatalogModel recommendModel(int recommendedMaxBytes) {
  if (recommendedMaxBytes <= 0) return kModelCatalog.firstWhere((m) => m.params == '1.5B');
  final fits = kModelCatalog.where((m) => m.approxBytes <= recommendedMaxBytes && m.tag != 'Kuat').toList();
  if (fits.isEmpty) return kModelCatalog.first; // perangkat sangat terbatas: model terkecil
  fits.sort((a, b) => b.approxBytes.compareTo(a.approxBytes));
  return fits.first;
}

/// Urutan kuantisasi yang dicoba: kompromi terbaik kualitas vs ukuran untuk HP.
const _quantOrder = ['Q4_K_M', 'Q4_K_S', 'Q4_0', 'Q5_K_M', 'Q3_K_M', 'Q8_0'];

/// Memilih satu file GGUF utuh (bukan shard/mmproj/imatrix) dari daftar file repo.
Map<String, dynamic>? pickGguf(List<Map<String, dynamic>> files) {
  final ggufs = files.where((f) {
    final n = '${f['name']}'.toLowerCase();
    return n.endsWith('.gguf') &&
        !n.contains('mmproj') &&
        !n.contains('imatrix') &&
        !RegExp(r'-\d{5}-of-\d{5}').hasMatch(n);
  }).toList();
  if (ggufs.isEmpty) return null;
  for (final q in _quantOrder) {
    for (final f in ggufs) {
      if ('${f['name']}'.toLowerCase().contains(q.toLowerCase())) return f;
    }
  }
  ggufs.sort((a, b) => ((a['size'] as num?) ?? 0).compareTo((b['size'] as num?) ?? 0));
  return ggufs.first;
}

String _bytes(num? v) {
  final n = (v ?? 0).toDouble();
  if (n <= 0) return '—';
  if (n >= 1024 * 1024 * 1024) return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  if (n >= 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(0)} MB';
  return '${(n / 1024).toStringAsFixed(0)} KB';
}

String _rate(num? v) => (v ?? 0) <= 0 ? '—' : '${_bytes(v)}/dtk';

String _eta(num? v) {
  final s = (v ?? -1).toInt();
  if (s < 0) return '—';
  if (s >= 3600) return '${s ~/ 3600} j ${(s % 3600) ~/ 60} mnt';
  if (s >= 60) return '${s ~/ 60} mnt ${s % 60} dtk';
  return '$s dtk';
}

/// Alur lengkap model lokal: pilih dari katalog → unduh (progres, jeda, batal) → aktif otomatis → mulai chat.
class ModelHubPage extends StatefulWidget {
  const ModelHubPage({
    super.key,
    required this.onLog,
    required this.onOpenChat,
    this.onOpenAdvanced,
    this.autoStartRepo = '',
  });
  final String autoStartRepo; // bila diisi, unduhan model katalog ini dimulai otomatis (dari onboarding)
  final void Function(String level, String message) onLog;
  final VoidCallback onOpenChat;
  final VoidCallback? onOpenAdvanced;

  @override
  State<ModelHubPage> createState() => _ModelHubPageState();
}

class _ModelHubPageState extends State<ModelHubPage> {
  Map<String, dynamic> _health = const {};
  EngineSettings? _engine;
  List<Map<String, dynamic>> _installed = [];
  final Map<String, Map<String, dynamic>> _updates = {};
  String? _pendingRevision;

  String? _resolvingRepo;
  CatalogModel? _current;
  String? _currentFile;
  String? _downloadId;
  Map<String, dynamic> _state = const {};
  bool _paused = false;
  Timer? _poll;

  String _message = '';
  bool _isError = false;
  bool _justReady = false;
  bool _loaded = false;
  bool _runBusy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  static const _dlKey = 'neuron.hub.download.v1';

  Future<void> _init() async {
    await _refresh();
    await _checkTrackedUpdates();
    await _restoreDownload();
    final repo = widget.autoStartRepo;
    if (repo.isNotEmpty && !_downloading && mounted) {
      final match = kModelCatalog.where((m) => m.repo == repo);
      if (match.isNotEmpty) await _start(match.first);
    }
  }

  Future<void> _checkTrackedUpdates() async {
    for (final model in _installed.where((m) => '${m['sourceRepo'] ?? ''}'.isNotEmpty)) {
      try {
        final status = await Bridge.checkLocalModelUpdate('${model['path']}');
        if (!mounted) return;
        setState(() => _updates['${model['path']}'] = status);
        if (status['updateAvailable'] == true && _message.isEmpty) {
          _say('Pembaruan model tersedia di Hugging Face: ${status['repo']}. Model yang ada tetap aman dan tidak ditimpa otomatis.');
        }
      } catch (_) {}
    }
  }

  Future<void> _saveDownload(String id, String repo, String file, String revision) async {
    try {
      (await SharedPreferences.getInstance()).setString(_dlKey, jsonEncode({'id': id, 'repo': repo, 'file': file, 'revision': revision}));
    } catch (_) {}
  }

  Future<void> _clearSavedDownload() async {
    try {
      (await SharedPreferences.getInstance()).remove(_dlKey);
    } catch (_) {}
  }

  /// Pulihkan unduhan yang masih berjalan (atau baru selesai) bila halaman ditutup lalu dibuka lagi.
  Future<void> _restoreDownload() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_dlKey);
      if (raw == null) return;
      final j = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final id = '${j['id']}';
      final st = await Bridge.hfDownloadState(id);
      final s = '${st['state']}';
      if (!['enqueued', 'running', 'blocked', 'succeeded'].contains(s)) {
        await _clearSavedDownload();
        return;
      }
      final match = kModelCatalog.where((m) => m.repo == '${j['repo']}');
      if (!mounted) return;
      setState(() {
        _current = match.isEmpty ? null : match.first;
        _pendingRevision = '${j['revision'] ?? ''}';
        _currentFile = '${j['file']}';
        _downloadId = id;
        _state = st;
        _paused = false;
      });
      if (s == 'succeeded') {
        await _tick();
      } else {
        _poll?.cancel();
        _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _isError = error;
    });
  }

  Future<void> _refresh() async {
    try {
      final health = await Bridge.deviceHealth();
      if (mounted) setState(() => _health = health);
    } catch (_) {}
    try {
      final engine = await Bridge.loadEngine();
      if (mounted) setState(() => _engine = engine);
    } catch (_) {}
    try {
      final st = await Bridge.modelState();
      if (mounted) setState(() => _loaded = st['loaded'] == true);
    } catch (_) {}
    try {
      final models = await Bridge.localModels();
      if (mounted) setState(() => _installed = models);
    } catch (e) {
      _say('Daftar model belum dapat dimuat: $e', error: true);
    }
  }

  int get _recommendedMax => (_health['recommendedMaxModel'] as num?)?.toInt() ?? 0;

  ({String label, Color color, bool heavy}) _fit(int bytes) {
    final max = _recommendedMax;
    if (max <= 0) return (label: 'Perkiraan ${_bytes(bytes)}', color: muted, heavy: false);
    if (bytes <= max) return (label: 'Cocok untuk perangkat ini', color: green, heavy: false);
    if (bytes <= max * 1.4) return (label: 'Mungkin lambat', color: amber, heavy: false);
    return (label: 'Kemungkinan terlalu berat', color: errorRed, heavy: true);
  }

  int get _flowStep {
    final e = _engine;
    final hasModel = e != null && e.mode == 'LOCAL' && e.modelPath.isNotEmpty;
    return flowStepFor(downloading: _downloading, hasModel: hasModel, loaded: _loaded);
  }

  bool get _downloading => _downloadId != null || _resolvingRepo != null;

  Future<void> _start(CatalogModel m) async {
    if (_downloading) return;
    final fit = _fit(m.approxBytes);
    if (fit.heavy) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: panel,
          title: const Text('Model mungkin terlalu berat'),
          content: Text(
              '${m.title} (~${_bytes(m.approxBytes)}) melebihi ukuran yang disarankan untuk RAM perangkat ini. Aplikasi bisa lambat atau tertutup saat memuat model. Tetap unduh?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Tetap unduh')),
          ],
        ),
      );
      if (go != true) return;
    }
    setState(() {
      _resolvingRepo = m.repo;
      _justReady = false;
      _message = '';
    });
    try {
      _pendingRevision = '${(await Bridge.hfRevision(m.repo))['revision'] ?? ''}';
      final files = await Bridge.hfFiles(m.repo);
      final file = pickGguf(files);
      if (file == null) throw Exception('Tidak ada file GGUF yang cocok di repo ini.');
      final size = (file['size'] as num?)?.toInt() ?? 0;
      final free = (_health['freeStorage'] as num?)?.toInt() ?? 0;
      if (size > 0 && free > 0 && size * 1.1 > free) {
        throw Exception('Ruang penyimpanan tidak cukup: butuh ${_bytes(size)}, tersedia ${_bytes(free)}.');
      }
      final started = await Bridge.hfStartDownload(m.repo, '${file['name']}', revision: _pendingRevision ?? '');
      final id = started['id']?.toString();
      if (id == null) throw Exception('ID unduhan tidak tersedia');
      await _saveDownload(id, m.repo, '${file['name']}', _pendingRevision ?? '');
      if (!mounted) return;
      setState(() {
        _current = m;
        _currentFile = '${file['name']}';
        _downloadId = id;
        _paused = false;
        _state = {'state': 'enqueued', 'file': file['name'], 'done': 0, 'total': size};
      });
      widget.onLog('INFO', 'Unduh model ${m.title}: ${file['name']}');
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    } catch (e) {
      _say('Gagal memulai unduhan: ${friendlyError(e)}', error: true);
      widget.onLog('ERROR', 'Unduh model gagal: $e');
    } finally {
      if (mounted) setState(() => _resolvingRepo = null);
    }
  }

  Future<void> _tick() async {
    final id = _downloadId;
    if (id == null) return;
    Map<String, dynamic> s;
    try {
      s = await Bridge.hfDownloadState(id);
    } catch (_) {
      return; // gangguan sesaat; coba lagi pada tick berikutnya
    }
    if (!mounted) return;
    setState(() => _state = s);
    final status = s['state']?.toString();
    if (status != 'succeeded' && status != 'failed' && status != 'cancelled') return;

    _poll?.cancel();
    final model = _current;
    unawaited(_clearSavedDownload());
    setState(() {
      _downloadId = null;
      _paused = false;
    });
    if (status == 'cancelled') {
      _say('Unduhan dibatalkan.');
      return;
    }
    if (status == 'failed') {
      final err = '${s['error'] ?? ''}'.trim();
      _say('Unduhan gagal${err.isEmpty ? '' : ': ${friendlyError(err)}'}. Coba lagi; unduhan yang terputus bisa dilanjutkan.', error: true);
      widget.onLog('ERROR', 'Unduh model gagal: $err');
      return;
    }
    final path = '${s['modelPath'] ?? ''}';
    if (!path.toLowerCase().endsWith('.gguf')) {
      _say('Unduhan selesai, tetapi bukan berkas GGUF sehingga tidak dapat dijalankan.', error: true);
      return;
    }
    try {
      final repo = model?.repo;
      final revision = _pendingRevision;
      if (repo != null && revision != null && revision.isNotEmpty) {
        await Bridge.trackLocalModelSource(path, repo, revision);
      }
      final result = await Bridge.activateLocalModel(path);
      _pendingRevision = null;
      await _refresh();
      final native = result['nativeAvailable'] == true;
      if (!mounted) return;
      setState(() => _justReady = true);
      _say(native
          ? '${model?.title ?? 'Model'} siap dan sudah aktif. Model dimuat saat pesan pertama dikirim.'
          : '${model?.title ?? 'Model'} terunduh dan dipilih, tetapi APK ini belum menyertakan library native llama.cpp (build dengan -PwithNative) sehingga chat lokal belum bisa berjalan.',
          error: !native);
      widget.onLog('INFO', 'Model lokal aktif: $path');
    } catch (e) {
      _say('Unduhan selesai, tetapi model belum bisa diaktifkan: ${friendlyError(e)}', error: true);
    }
  }

  Future<void> _pauseOrResume() async {
    final id = _downloadId;
    if (id == null) return;
    try {
      if (_paused) {
        final r = await Bridge.hfResumeDownload(id);
        if (!mounted) return;
        setState(() {
          _downloadId = r['id']?.toString() ?? id;
          _paused = false;
        });
        _poll?.cancel();
        _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
      } else {
        await Bridge.hfPauseDownload(id);
        _poll?.cancel();
        if (mounted) setState(() => _paused = true);
      }
    } catch (e) {
      _say('Gagal ${_paused ? 'melanjutkan' : 'menjeda'} unduhan: $e', error: true);
    }
  }

  Future<void> _cancel() async {
    final id = _downloadId;
    if (id == null) return;
    _poll?.cancel();
    try {
      await Bridge.hfCancelDownload(id);
    } catch (_) {}
    unawaited(_clearSavedDownload());
    if (!mounted) return;
    setState(() {
      _downloadId = null;
      _paused = false;
    });
    _say('Unduhan dibatalkan.');
  }

  Future<void> _use(String path) async {
    try {
      final r = await Bridge.activateLocalModel(path);
      await _refresh();
      if (!mounted) return;
      setState(() => _justReady = true);
      _say(r['nativeAvailable'] == true
          ? 'Model diaktifkan.'
          : 'Model dipilih, tetapi library native llama.cpp belum ada di APK ini.',
          error: r['nativeAvailable'] != true);
    } catch (e) {
      _say('Gagal mengaktifkan model: ${friendlyError(e)}', error: true);
    }
  }

  Future<void> _delete(Map<String, dynamic> model) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        title: const Text('Hapus model?'),
        content: Text('${model['name']} (${_bytes(model['size'] as num?)}) akan dihapus dari perangkat.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hapus')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Bridge.deleteLocalModel('${model['path']}');
      await _refresh();
      _say('Model dihapus.');
    } catch (e) {
      _say('Gagal menghapus model: $e', error: true);
    }
  }

  /// Muat model ke memori sekarang agar pesan chat pertama tidak menunggu.
  Future<void> _run() async {
    if (_runBusy) return;
    // Peringatan RAM rendah sebelum memuat: model + cache KV butuh sekitar 1.2x ukuran file.
    try {
      final health = await Bridge.deviceHealth();
      final avail = (health['availableRam'] as num?)?.toInt() ?? 0;
      final active = _installed.where((m) => m['active'] == true);
      final size = active.isEmpty ? 0 : ((active.first['size'] as num?)?.toInt() ?? 0);
      if (size > 0 && avail > 0 && avail < size * 1.2 && mounted) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: panel,
            title: const Text('RAM bebas rendah'),
            content: Text('RAM bebas ${_bytes(avail)}, model ${_bytes(size)}. Menjalankan sekarang bisa membuat aplikasi lambat atau tertutup. Tutup aplikasi lain dulu, atau pilih model lebih kecil. Tetap jalankan?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Tetap jalankan')),
            ],
          ),
        );
        if (go != true) return;
      }
    } catch (_) {}
    setState(() => _runBusy = true);
    try {
      final r = await Bridge.runModel();
      final secs = (((r['ms'] as num?) ?? 0) / 1000).toStringAsFixed(1);
      final warnings = ((r['warnings'] as List?) ?? const []).map((w) => '$w').toList();
      if (warnings.isEmpty) {
        _say('Model berjalan di memori (dimuat dalam $secs dtk). Siap dipakai chat.');
      } else {
        // Model termuat, tetapi ada hal yang perlu diketahui (mis. template chat tidak dikenali, memakai ChatML).
        _say('Model berjalan di memori ($secs dtk), dengan peringatan: ${warnings.join(' ')}', error: true);
        for (final w in warnings) {
          widget.onLog('WARN', w);
        }
      }
      widget.onLog('INFO', 'Model dimuat ($secs dtk)');
    } catch (e) {
      _say('Model gagal dijalankan: ${friendlyError(e)}', error: true);
      widget.onLog('ERROR', 'Model gagal dimuat: $e');
    } finally {
      if (mounted) setState(() => _runBusy = false);
      await _refresh();
    }
  }

  Future<void> _stopModel() async {
    if (_runBusy) return;
    setState(() => _runBusy = true);
    try {
      await Bridge.unloadModel();
      _say('Model dilepas dari memori. RAM kembali bebas.');
    } catch (e) {
      _say('Gagal melepas model: $e', error: true);
    } finally {
      if (mounted) setState(() => _runBusy = false);
    }
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    await _refresh();
  }

  static const _paramsPath = 'chat/params.json';

  /// Edit prompt sistem dan parameter generate model (disimpan ke chat/params.json lewat validasi VirtualTree).
  Future<void> _editSettings() async {
    Map<String, dynamic> params;
    try {
      params = Map<String, dynamic>.from(jsonDecode(await Bridge.read(_paramsPath)) as Map);
    } catch (e) {
      _say('Pengaturan belum dapat dibaca: $e', error: true);
      return;
    }
    final system = TextEditingController(text: '${params['systemPrompt'] ?? ''}');
    final temp = TextEditingController(text: '${params['temperature'] ?? 0.8}');
    final maxTok = TextEditingController(text: '${params['maxTokens'] ?? 512}');
    final ctx = TextEditingController(text: '${params['contextLength'] ?? 4096}');
    if (!mounted) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: panel,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(c).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Pengaturan model', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              for (final p in kPromptPresets.entries)
                ActionChip(label: Text(p.key, style: const TextStyle(fontSize: 11)), onPressed: () => system.text = p.value),
            ]),
            const SizedBox(height: 8),
            TextField(controller: system, minLines: 3, maxLines: 8, decoration: const InputDecoration(labelText: 'Prompt sistem (kepribadian dan aturan jawaban)')),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: temp, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Temperature 0–2'))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: maxTok, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Maks token jawaban'))),
            ]),
            const SizedBox(height: 10),
            TextField(controller: ctx, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Panjang konteks (token)', helperText: 'Lebih besar = lebih banyak RAM. Model dimuat ulang bila berubah.')),
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Simpan')),
            ]),
          ]),
        ),
      ),
    );
    final values = (system.text, temp.text, maxTok.text, ctx.text);
    system.dispose();
    temp.dispose();
    maxTok.dispose();
    ctx.dispose();
    if (saved != true) return;
    final t = double.tryParse(values.$2.replaceAll(',', '.'));
    final m = int.tryParse(values.$3);
    final c = int.tryParse(values.$4);
    if (t == null || t < 0 || t > 2 || m == null || m < 16 || m > 8192 || c == null || c < 512 || c > 32768) {
      _say('Nilai tidak valid. Temperature 0–2, maks token 16–8192, konteks 512–32768.', error: true);
      return;
    }
    params['systemPrompt'] = values.$1;
    params['temperature'] = t;
    params['maxTokens'] = m;
    params['contextLength'] = c;
    try {
      await Bridge.write(_paramsPath, const JsonEncoder.withIndent('  ').convert(params));
      _say('Pengaturan disimpan. Berlaku pada pesan berikutnya.');
      widget.onLog('INFO', 'chat/params.json diperbarui dari Model Hub');
      await _refresh();
    } catch (e) {
      _say('Pengaturan ditolak: $e', error: true);
    }
  }

  Future<void> _rename(Map<String, dynamic> model) async {
    final current = '${model['name']}';
    final ctrl = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: panel,
        title: const Text('Ganti nama model'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(helperText: 'Tetap berakhiran .gguf')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Simpan')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || name == current) return;
    try {
      await Bridge.renameLocalModel('${model['path']}', name);
      await _refresh();
      _say('Nama model diubah.');
    } catch (e) {
      _say('Gagal mengganti nama: $e', error: true);
    }
  }

  Future<void> _checkInstalledUpdate(Map<String, dynamic> model) async {
    final path = '${model['path']}';
    try {
      final status = await Bridge.checkLocalModelUpdate(path);
      if (!mounted) return;
      setState(() => _updates[path] = status);
      _say(status['updateAvailable'] == true
          ? 'Pembaruan tersedia untuk ${status['repo']}. Model saat ini tidak diubah. Buka pencarian Hugging Face untuk meninjau versi baru.'
          : 'Model ${status['repo']} sudah memakai revision terbaru yang terdeteksi.');
    } catch (e) {
      _say('Pemeriksaan pembaruan gagal: $e', error: true);
    }
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Model Hub', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text(
          'Unduh model GGUF, aktifkan, lalu pakai untuk chat dan perbaikan Copilot. Semua berjalan di perangkat.',
          style: TextStyle(color: muted, fontSize: 12, height: 1.4)),
      const SizedBox(height: 14),
      FlowStepper(current: _flowStep),
      const SizedBox(height: 10),
      _deviceCard(),
      const SizedBox(height: 10),
      _activeCard(),
      if (_message.isNotEmpty) _banner(),
      if (_downloading) _progressCard(),
      const SizedBox(height: 14),
      const Text('Katalog model', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      for (final m in kModelCatalog) _catalogCard(m),
      if (_installed.isNotEmpty) ...[
        const SizedBox(height: 14),
        const Text('Terpasang di perangkat', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (final m in _installed) _installedTile(m),
      ],
      if (widget.onOpenAdvanced != null) ...[
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: widget.onOpenAdvanced,
            icon: const Icon(Icons.search, size: 16),
            label: const Text('Cari model lain di Hugging Face'),
          ),
        ),
      ],
      const SizedBox(height: 18),
    ]);
  }

  Widget _deviceCard() {
    final ram = _health['totalRam'] as num?;
    final free = _health['freeStorage'] as num?;
    final max = _recommendedMax;
    return Card(
      color: panel,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          const Icon(Icons.phone_android_outlined, color: blue),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              ram == null
                  ? 'Memeriksa perangkat…'
                  : 'RAM ${_bytes(ram)} · Penyimpanan bebas ${_bytes(free)}'
                      '${max > 0 ? '\nUkuran model yang disarankan: hingga ${_bytes(max)}' : ''}',
              style: const TextStyle(fontSize: 11, color: muted, height: 1.45),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _activeCard() {
    final e = _engine;
    final local = e != null && e.mode == 'LOCAL' && e.modelPath.isNotEmpty;
    final name = local ? e.modelPath.split('/').last : null;
    return Card(
      color: panel,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Row(children: [
          Icon(local ? Icons.check_circle : Icons.info_outline, color: local ? green : amber),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(local ? 'Model aktif' : 'Belum ada model lokal aktif',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(name ?? 'Pilih satu model dari katalog di bawah untuk mulai.',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: muted)),
            ]),
          ),
        ]),
        if (local) ...[
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.circle, size: 8, color: _loaded ? green : muted),
            const SizedBox(width: 6),
            Expanded(child: Text(_loaded ? 'Berjalan di memori' : 'Belum dimuat ke memori', style: TextStyle(fontSize: 10, color: _loaded ? green : muted))),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (_loaded)
              OutlinedButton.icon(onPressed: _runBusy ? null : _stopModel, icon: const Icon(Icons.stop_circle_outlined, size: 16), label: const Text('Hentikan'))
            else
              FilledButton.icon(
                onPressed: _runBusy ? null : _run,
                icon: _runBusy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow, size: 18),
                label: Text(_runBusy ? 'Memuat…' : 'Jalankan'),
                style: FilledButton.styleFrom(backgroundColor: green, foregroundColor: Colors.black),
              ),
            FilledButton.icon(onPressed: widget.onOpenChat, icon: const Icon(Icons.chat_bubble_outline, size: 16), label: const Text('Chat'), style: FilledButton.styleFrom(backgroundColor: blue)),
            OutlinedButton.icon(onPressed: _editSettings, icon: const Icon(Icons.tune, size: 16), label: const Text('Pengaturan')),
          ]),
        ],
      ])),
    );
  }

  Widget _banner() => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: panel2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _isError ? errorRed : (_justReady ? green : line)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(_message, style: const TextStyle(fontSize: 11, height: 1.45)),
          if (_justReady && !_isError) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: widget.onOpenChat,
              icon: const Icon(Icons.chat_bubble_outline, size: 16),
              label: const Text('Mulai chat dengan model ini'),
              style: FilledButton.styleFrom(backgroundColor: blue),
            ),
          ],
        ]),
      );

  Widget _progressCard() {
    final total = (_state['total'] as num?)?.toDouble() ?? -1;
    final done = (_state['done'] as num?)?.toDouble() ?? 0;
    final value = total > 0 ? (done / total).clamp(0.0, 1.0) : null;
    final resolving = _resolvingRepo != null && _downloadId == null;
    return Card(
      color: panel,
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(resolving ? 'Mencari file GGUF terbaik…' : (_current?.title ?? 'Mengunduh'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          if (_currentFile != null && !resolving)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(_currentFile!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: muted)),
            ),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: resolving ? null : value, minHeight: 6, borderRadius: BorderRadius.circular(6)),
          const SizedBox(height: 8),
          if (!resolving)
            Text(
              _paused
                  ? 'Dijeda · ${_bytes(done)} / ${_bytes(total)}'
                  : '${_bytes(done)} / ${_bytes(total)} · ${_rate(_state['speed'] as num?)} · sisa ${_eta(_state['eta'] as num?)}',
              style: const TextStyle(fontSize: 11, color: muted),
            ),
          if (!resolving)
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: _pauseOrResume, child: Text(_paused ? 'Lanjutkan' : 'Jeda')),
              TextButton(onPressed: _cancel, child: const Text('Batal')),
            ]),
        ]),
      ),
    );
  }

  Color _tagColor(String tag) => switch (tag) {
        'Ringan' => green,
        'Seimbang' => blue,
        _ => purple,
      };

  Widget _catalogCard(CatalogModel m) {
    final fit = _fit(m.approxBytes);
    final busy = _downloading;
    return Card(
      color: panel,
      margin: const EdgeInsets.only(bottom: 9),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(m.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: _tagColor(m.tag).withAlpha(41), borderRadius: BorderRadius.circular(20)),
              child: Text(m.tag, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: _tagColor(m.tag))),
            ),
          ]),
          const SizedBox(height: 4),
          Text('${m.params} parameter · GGUF · ~${_bytes(m.approxBytes)}', style: const TextStyle(fontSize: 10, color: muted)),
          const SizedBox(height: 6),
          Text(m.note, style: const TextStyle(fontSize: 11, height: 1.4)),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.circle, size: 8, color: fit.color),
            const SizedBox(width: 6),
            Expanded(child: Text(fit.label, style: TextStyle(fontSize: 10, color: fit.color))),
            FilledButton.icon(
              onPressed: busy ? null : () => _start(m),
              icon: const Icon(Icons.download, size: 15),
              label: const Text('Unduh & pakai', style: TextStyle(fontSize: 11)),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 36), backgroundColor: blue),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _installedTile(Map<String, dynamic> m) {
    final active = m['active'] == true;
    final update = _updates['${m['path']}']?['updateAvailable'] == true;
    return Card(
      color: panel2,
      margin: const EdgeInsets.only(bottom: 7),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(active ? Icons.check_circle : Icons.memory_outlined, color: active ? green : purple),
        title: Text('${m['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        subtitle: Text('${_bytes(m['size'] as num?)} · ${active ? 'aktif' : 'tersedia'}${update ? ' · PEMBARUAN HF' : ''}', style: TextStyle(fontSize: 10, color: update ? amber : muted)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if ('${m['sourceRepo'] ?? ''}'.isNotEmpty) IconButton(tooltip: 'Periksa pembaruan HF', onPressed: () => _checkInstalledUpdate(m), icon: Icon(update ? Icons.system_update_alt : Icons.refresh, size: 18, color: update ? amber : muted)),
          if (!active) TextButton(onPressed: () => _use('${m['path']}'), child: const Text('Pakai')),
          IconButton(tooltip: 'Ganti nama', onPressed: () => _rename(m), icon: const Icon(Icons.edit_outlined, size: 18, color: muted)),
          if (!active)
            IconButton(
              tooltip: 'Hapus',
              onPressed: () => _delete(m),
              icon: const Icon(Icons.delete_outline, size: 18, color: muted),
            ),
        ]),
      ),
    );
  }
}
