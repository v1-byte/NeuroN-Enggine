import 'dart:async';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'bridge.dart';
import 'gguf_editor.dart';
import 'model_editor_page.dart';
import 'lora_page.dart';
import 'model_hub.dart';
import 'theme.dart';
import 'training_page.dart';
import 'weight_ops_page.dart';

class FeatureWorkspace extends StatefulWidget {
  const FeatureWorkspace({super.key, required this.page, required this.onLog, required this.onBack, this.onOpenChat, this.onOpenPage, this.initialComplaint = '', this.initialSample = '', this.hubAutoStartRepo = '', this.initialModelPath = '', this.onEditModel, this.onGoSection, this.onGuardrailChanged});
  final String hubAutoStartRepo;
  /// Model yang langsung dibuka di Editor GGUF (kosong = pilih sendiri).
  final String initialModelPath;
  /// Dipanggil dengan path model untuk membuka Editor GGUF dari daftar Model lokal.
  final ValueChanged<String>? onEditModel;
  /// Pindah ke bagian utama aplikasi ('Library', 'Import', ...).
  final void Function(String section)? onGoSection;
  final VoidCallback? onGuardrailChanged;
  final String page;
  final void Function(String level, String message) onLog;
  final VoidCallback onBack;
  final VoidCallback? onOpenChat;
  final void Function(String page)? onOpenPage;
  final String initialComplaint;
  final String initialSample;
  @override
  State<FeatureWorkspace> createState() => _FeatureWorkspaceState();
}

class _FeatureWorkspaceState extends State<FeatureWorkspace> {
  static const _hfFullModelExamples = <String, String>{
    'SmolLM2 · 360M': 'HuggingFaceTB/SmolLM2-360M-Instruct',
    'Qwen2.5 · 0.5B': 'Qwen/Qwen2.5-0.5B-Instruct',
    'TinyLlama · 1.1B': 'TinyLlama/TinyLlama-1.1B-Chat-v1.0',
  };

  final _query = TextEditingController();
  final _repo = TextEditingController();
  final _hfToken = TextEditingController();
  final _complaint = TextEditingController();
  final _sample = TextEditingController();
  bool _busy = false;
  String _status = '';
  List<Map<String, dynamic>> _models = [];
  List<Map<String, dynamic>> _files = [];
  List<Map<String, dynamic>> _localModels = [];
  final Map<String, Map<String, dynamic>> _localUpdates = {};
  List<Map<String, dynamic>> _downloadHistory = [];
  Map<String, dynamic> _rag = {};
  String? _repoSelected;
  String? _downloadId;
  String? _downloadRepo;
  String? _downloadRevision;
  bool _downloadPaused = false;
  bool _downloadIsFullModel = false;
  String _sizeFilter = 'Semua';
  String _quantFilter = 'Semua';
  String _hfScope = 'all';
  bool? _hfNativeAvailable;
  Timer? _downloadPoll;
  Map<String, dynamic> _downloadState = const {};
  Map<String, dynamic> _health = const {};
  List<Map<String, dynamic>> _copilotChanges = [];
  final Set<String> _reviewedCopilotPaths = {};

  @override
  void initState() {
    super.initState();
    if (widget.page == 'Copilot') {
      _complaint.text = widget.initialComplaint;
      _sample.text = widget.initialSample;
    }
    if (widget.page == 'Data & RAG') _loadRag();
    if (widget.page == 'Model lokal') _loadLocalModels();
    if (widget.page == 'Hardware') _loadHealth();
    if (widget.page == 'Hugging Face') {
      _loadDownloadHistory();
      _loadHfRuntimeStatus();
      _loadLocalModels();
    }
  }

  @override
  void dispose() {
    _downloadPoll?.cancel();
    _query.dispose();
    _repo.dispose();
    _hfToken.dispose();
    _complaint.dispose();
    _sample.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() { _busy = true; _status = ''; });
    try { await task(); }
    catch (e) { if (mounted) setState(() => _status = 'Gagal: $e'); widget.onLog('ERROR', '$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _loadRag() async {
    try { final s = await Bridge.knowledgeState(); if (mounted) setState(() => _rag = s); }
    catch (e) { if (mounted) setState(() => _status = 'RAG belum dapat diakses: $e'); }
  }

  Future<void> _pickLocalModel() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['gguf']);
    final path = picked?.files.single.path;
    if (path == null) return;
    await _run(() async {
      final result = await Bridge.setLocalModel(path);
      final native = result['nativeAvailable'] == true;
      setState(() => _status = native
          ? 'Model disimpan. Mode lokal aktif; engine akan memuat model saat chat berikutnya.'
          : 'Model disimpan, tetapi library native belum tersedia. Build APK dengan llama.cpp (-PwithNative) sebelum inferensi lokal.');
      widget.onLog('INFO', 'Model GGUF lokal dipilih: ${result['path']}');
    });
  }

  Future<void> _loadLocalModels() async {
    try {
      final models = await Bridge.localModels();
      if (mounted) setState(() => _localModels = models);
      if (widget.page == 'Hugging Face') {
        for (final model in models.where((m) => '${m['sourceRepo'] ?? ''}'.isNotEmpty)) {
          final path = '${model['path']}';
          try {
            final status = await Bridge.checkLocalModelUpdate(path);
            if (mounted) setState(() => _localUpdates[path] = status);
          } catch (_) {}
        }
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Model lokal belum dapat dimuat: $e');
    }
  }

  Future<void> _loadHealth({int modelSize = 0}) async {
    try {
      final health = await Bridge.deviceHealth(modelSize: modelSize);
      if (mounted) setState(() => _health = health);
    } catch (e) {
      if (mounted) setState(() => _status = 'Health check belum dapat diakses: $e');
    }
  }

  Future<void> _loadDownloadHistory() async {
    try {
      final history = await Bridge.hfDownloadHistory();
      if (mounted) setState(() => _downloadHistory = history);
    } catch (e) {
      if (mounted) setState(() => _status = 'Riwayat download belum tersedia: $e');
    }
  }

  Future<void> _loadHfRuntimeStatus() async {
    try {
      final settings = await Bridge.loadEngine();
      if (mounted) setState(() => _hfNativeAvailable = settings.nativeAvailable);
    } catch (_) {
      if (mounted) setState(() => _hfNativeAvailable = false);
    }
  }

  Future<void> _deleteLocalModel(String path) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Hapus model?'),
            content: const Text('File model akan dihapus dari penyimpanan NeuroN dan tidak dapat dipulihkan.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Batal')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Hapus')),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _run(() async {
      await Bridge.deleteLocalModel(path);
      await _loadLocalModels();
      setState(() => _status = 'Model dihapus dengan aman.');
    });
  }

  Future<void> _renameLocalModel(String path, String currentName) async {
    final controller = TextEditingController(text: currentName.replaceAll(RegExp(r'\.gguf$'), ''));
    final name = await showDialog<String>(context: context, builder: (dialogContext) => AlertDialog(title: const Text('Rename model'), content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Nama model')), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Batal')), FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text), child: const Text('Simpan'))]));
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    await _run(() async { await Bridge.renameLocalModel(path, name.trim()); await _loadLocalModels(); setState(() => _status = 'Nama model diperbarui.'); });
  }

  Future<void> _verifyLocalModel(String path) async => _run(() async {
        final result = await Bridge.verifyLocalModel(path);
        setState(() => _status = 'Verifikasi berhasil. SHA-256: ${result['sha256']}');
      });

  Future<void> _showModelMetadata(String path) async {
    final metadata = await Bridge.exportLocalModelMetadata(path);
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(title: const Text('Metadata model'), content: SelectableText(metadata.entries.map((e) => '${e.key}: ${e.value}').join('\n')), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Tutup'))]));
  }

  Future<void> _activateLocalModel(String path) async => _run(() async {
        final result = await Bridge.activateLocalModel(path);
        await _loadLocalModels();
        setState(() => _status = result['nativeAvailable'] == true
            ? 'Model aktif. Mode lokal siap digunakan.'
            : 'Model aktif, tetapi library native belum tersedia pada APK ini.');
        widget.onLog('INFO', 'Model lokal diaktifkan: $path');
      });

  Future<void> _searchHf() async => _run(() async {
    final query = _query.text.trim().toLowerCase();
    final local = await Bridge.localModels();
    final found = query.isEmpty ? <Map<String, dynamic>>[] : await Bridge.hfSearch(_query.text.trim(), scope: _hfScope);
    setState(() { _localModels = local; _models = found; _files = []; _repoSelected = null; });
    _status = query.isEmpty ? '${local.length} model lokal tersedia' : '${found.length} repo HF dan ${local.where((m) => '${m['name']}'.toLowerCase().contains(query) || '${m['sourceRepo'] ?? ''}'.toLowerCase().contains(query)).length} model lokal cocok';
  });

  Future<void> _selectRepo(String id) async => _run(() async {
    final found = await Bridge.hfFiles(id);
    setState(() { _repo.text = id; _repoSelected = id; _files = found; });
    _status = '${found.length} file repo ditemukan; unduhan model lengkap mendukung bobot standar dan file tokenizer/config.';
  });

  List<Map<String, dynamic>> _fullModelFiles() {
    List<Map<String, dynamic>>? weights;
    for (final extension in const ['.safetensors', '.bin', '.onnx', '.pt', '.pth', '.h5']) {
      final matches = _files.where((file) => '${file['name']}'.toLowerCase().endsWith(extension)).toList();
      if (matches.isNotEmpty) {
        weights = matches;
        break;
      }
    }
    if (weights == null) return [];
    const metadataExtensions = ['.json', '.model', '.txt', '.tiktoken', '.vocab', '.merges', '.jinja', '.yaml', '.yml'];
    final names = <String>{};
    return [
      ...weights,
      ..._files.where((file) => metadataExtensions.any(
            (extension) => '${file['name']}'.toLowerCase().endsWith(extension),
          )),
    ].where((file) => names.add('${file['name']}')).toList();
  }

  Widget _fullModelDownloadControl(String repo) {
    final files = _fullModelFiles();
    final total = files.fold<num>(0, (sum, file) => sum + ((file['size'] as num?) ?? 0));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Unduh semua shard bobot standar beserta tokenizer dan konfigurasi. File akan disimpan dalam folder repo; format non-GGUF belum dapat dijalankan langsung secara lokal.', style: TextStyle(color: muted, fontSize: 10)),
        const SizedBox(height: 6),
        FilledButton.icon(
          onPressed: _busy || _downloadId != null || files.isEmpty ? null : () => _downloadFullModel(repo),
          icon: const Icon(Icons.downloading),
          label: Text(files.isEmpty ? 'Bobot standar tidak tersedia' : 'Unduh model lengkap · ${files.length} file · ${_bytes(total)}'),
        ),
      ]),
    );
  }

  Future<void> _downloadFullModel(String repo) async {
    if (_downloadId != null) return;
    final files = _fullModelFiles();
    if (files.isEmpty) return;
    final names = files.map((file) => '${file['name']}').toList();
    final estimatedTotal = files.fold<int>(0, (sum, file) => sum + ((file['size'] as num?)?.toInt() ?? 0));
    await _run(() async {
      final revision = '${(await Bridge.hfRevision(repo))['revision'] ?? ''}';
      final started = await Bridge.hfStartModelDownload(repo, names, revision: revision);
      _downloadId = started['id']?.toString();
      if (_downloadId == null) throw Exception('ID unduhan tidak tersedia');
      _downloadRepo = repo;
      _downloadRevision = revision;
      _downloadIsFullModel = true;
      _downloadState = <String, dynamic>{'state': 'enqueued', 'file': names.first, 'index': 0, 'count': names.length, 'done': 0, 'total': -1, 'modelDone': 0, 'modelTotal': estimatedTotal > 0 ? estimatedTotal : -1};
      _downloadPaused = false;
      setState(() => _status = 'Mengunduh model lengkap (${names.length} file) di background…');
      _downloadPoll?.cancel();
      _downloadPoll = Timer.periodic(const Duration(milliseconds: 500), (_) => _pollDownload());
    });
  }

  Future<void> _download(String repo, String file) async {
    if (_downloadId != null) return;
    await _run(() async {
      final revision = '${(await Bridge.hfRevision(repo))['revision'] ?? ''}';
      final started = await Bridge.hfStartDownload(repo, file, revision: revision);
      _downloadId = started['id']?.toString();
      if (_downloadId == null) throw Exception('ID unduhan tidak tersedia');
      _downloadRepo = repo;
      _downloadRevision = revision;
      _downloadIsFullModel = false;
      _downloadState = <String, dynamic>{'state': 'enqueued', 'file': file, 'done': 0, 'total': -1};
      _downloadPaused = false;
      setState(() => _status = 'Unduhan berjalan di background…');
      _downloadPoll?.cancel();
      _downloadPoll = Timer.periodic(const Duration(milliseconds: 500), (_) => _pollDownload());
    });
  }

  Future<void> _pollDownload() async {
    final id = _downloadId;
    if (id == null) return;
    Map<String, dynamic> state;
    try {
      state = await Bridge.hfDownloadState(id);
    } catch (e) {
      if (mounted) setState(() => _status = 'Status unduhan sementara tidak tersedia: $e');
      return;
    }
    if (!mounted) return;
    setState(() => _downloadState = state);
    final status = state['state']?.toString();
    if (status == 'succeeded' || status == 'failed' || status == 'cancelled') {
      _downloadPoll?.cancel();
      _downloadId = null;
      final modelPath = state['modelPath']?.toString() ?? '';
      final isGguf = modelPath.toLowerCase().endsWith('.gguf');
      final isFullModel = _downloadIsFullModel;
      var nativeReady = false;
      if (status == 'succeeded' && isGguf && !isFullModel) {
        try {
          final repo = _downloadRepo;
          final revision = _downloadRevision;
          if (repo != null && revision != null && revision.isNotEmpty) {
            await Bridge.trackLocalModelSource(modelPath, repo, revision);
          }
          final activation = await Bridge.activateLocalModel(modelPath);
          nativeReady = activation['nativeAvailable'] == true;
          await _loadLocalModels();
        } catch (e) {
          if (mounted) setState(() => _status = 'Unduhan selesai, tetapi model belum bisa diaktifkan: $e');
        }
      }
      setState(() {
        _status = status == 'succeeded'
            ? isFullModel
                ? 'Model lengkap selesai diunduh (${state['count'] ?? 0} file): ${state['path']}'
                : isGguf
                    ? nativeReady
                        ? 'GGUF diunduh dan siap dipakai lokal: ${state['path']}'
                        : 'GGUF diunduh dan dipilih, tetapi library native belum tersedia di APK ini: ${state['path']}'
                    : 'File diunduh: ${state['path']}. Format ini bukan GGUF, jadi belum bisa dijalankan langsung sebagai model lokal.'
            : status == 'cancelled'
                ? 'Unduhan dibatalkan.'
                : 'Unduhan gagal: ${state['error']}';
      _downloadIsFullModel = false;
      _downloadRepo = null;
      _downloadRevision = null;
      });
      await _loadDownloadHistory();
    }
  }

  Future<void> _cancelDownload() async {
    final id = _downloadId;
    if (id == null) return;
    await Bridge.hfCancelDownload(id);
    _downloadPoll?.cancel();
    if (mounted) setState(() { _downloadId = null; _downloadIsFullModel = false; _status = 'Permintaan pembatalan dikirim.'; });
  }

  Future<void> _pauseOrResumeDownload() async {
    final id = _downloadId;
    if (id == null) return;
    if (_downloadPaused) {
      final resumed = await Bridge.hfResumeDownload(id);
      if (mounted) setState(() { _downloadId = resumed['id']?.toString() ?? id; _downloadPaused = false; _status = 'Unduhan dilanjutkan.'; });
      _downloadPoll?.cancel();
      _downloadPoll = Timer.periodic(const Duration(milliseconds: 500), (_) => _pollDownload());
    } else {
      await Bridge.hfPauseDownload(id);
      _downloadPoll?.cancel();
      if (mounted) setState(() { _downloadPaused = true; _status = 'Unduhan dijeda. Resume tetap tersedia.'; });
    }
  }

  bool _fileVisible(Map<String, dynamic> file) {
    final name = '${file['name']}'.toUpperCase();
    final size = (file['size'] as num?)?.toDouble() ?? 0;
    final sizeOk = switch (_sizeFilter) {
      '≤ 1 GB' => size <= 1e9,
      '1–3 GB' => size > 1e9 && size <= 3e9,
      '3–8 GB' => size > 3e9 && size <= 8e9,
      '> 8 GB' => size > 8e9,
      _ => true,
    };
    final quantOk = _quantFilter == 'Semua' || name.contains(_quantFilter);
    return sizeOk && quantOk;
  }

  Future<void> _addKnowledge() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom,
        allowedExtensions: const ['txt','md','markdown','csv','tsv','json','jsonl','pdf','docx','xml','html','py','kt','java','js','ts','yaml','yml']);
    final path = picked?.files.single.path;
    if (path == null) return;
    await _run(() async {
      final result = await Bridge.addKnowledgeFile(path);
      await _loadRag();
      setState(() => _status = 'Dokumen ditambahkan: ${result['name']}');
      widget.onLog('INFO', 'Dokumen RAG ditambahkan: ${result['name']}');
    });
  }

  Future<void> _index() async => _run(() async {
    final report = await Bridge.indexKnowledge();
    await _loadRag();
    setState(() => _status = 'Indeks selesai: ${report['indexed']} file baru, ${report['skipped']} tidak berubah, ${report['chunks']} chunk. Gagal: ${(report['failed'] as List?)?.join('; ') ?? '-'}');
    widget.onLog('INFO', 'Indeks pengetahuan selesai (${report['chunks']} chunk)');
  });

  @override
  Widget build(BuildContext context) {
    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: widget.onBack, icon: const Icon(Icons.arrow_back), label: const Text('Kembali ke Workspace'))),
      switch (widget.page) {
      'Model Hub' => ModelHubPage(autoStartRepo: widget.hubAutoStartRepo, onLog: widget.onLog, onOpenChat: widget.onOpenChat ?? widget.onBack, onOpenAdvanced: widget.onOpenPage == null ? null : () => widget.onOpenPage!('Hugging Face')),
      'Model lokal' => _localPage(),
      'Data & RAG' => _ragPage(),
      'Hugging Face' => _hfPage(),
      'Latih' => TrainingPage(onLog: widget.onLog),
      'Edit model' || 'Edit privasi' => ModelEditorPage(
          onLog: widget.onLog,
          initialPath: widget.initialModelPath.isEmpty ? null : widget.initialModelPath,
          initialTab: widget.page == 'Edit privasi' ? ModelEditTab.privacy : ModelEditTab.info,
          onOpenLibrary: widget.onGoSection == null ? null : () => widget.onGoSection!('Library'),
          onOpenImport: widget.onGoSection == null ? null : () => widget.onGoSection!('Import'),
          onGuardrailChanged: widget.onGuardrailChanged,
        ),
      'Editor GGUF' => GgufEditorPage(onLog: widget.onLog, initialPath: widget.initialModelPath.isEmpty ? null : widget.initialModelPath),
      'LoRA' => LoraPage(onLog: widget.onLog),
      'Ubah bobot' => WeightOpsPage(onLog: widget.onLog),
      'Copilot' => _copilotPage(),
      'Hardware' => _hardwarePage(),
      _ => _pendingPage(Icons.info_outline, widget.page, 'Fitur ini belum memiliki layar aktif.'),
      },
    ]);
    return ColoredBox(color: ink, child: Stack(children: [
      Positioned.fill(child: SingleChildScrollView(padding: const EdgeInsets.all(14), child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: content)))),
      if (_busy) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 2)),
    ]));
  }

  Widget _card(String title, String detail, {Widget? child, IconData? icon}) => Card(color: panel, child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [if (icon != null) ...[Icon(icon, color: purple), const SizedBox(width: 9)], Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)))]),
    const SizedBox(height: 8), Text(detail, style: const TextStyle(color: muted, height: 1.4, fontSize: 12)),
    if (child != null) ...[const SizedBox(height: 14), child],
  ])));

  Widget _message() => _status.isEmpty ? const SizedBox.shrink() : Container(width: double.infinity, margin: const EdgeInsets.only(top: 10), padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(9)), child: SelectableText(_status, style: const TextStyle(fontSize: 11, height: 1.4)));

  Widget _localPage() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _card('Model lokal', 'Impor GGUF dari Download atau penyimpanan internal. File disalin ke ruang aplikasi agar tetap tersedia, lalu Anda dapat mengaktifkan model tanpa memilih ulang.', icon: Icons.phone_android_outlined, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(onPressed: _busy ? null : _pickLocalModel, icon: const Icon(Icons.file_upload_outlined), label: const Text('Impor file GGUF')),
        OutlinedButton.icon(onPressed: _busy ? null : _loadLocalModels, icon: const Icon(Icons.refresh), label: const Text('Segarkan')),
      ]),
      const SizedBox(height: 12),
      if (_localModels.isEmpty) const Text('Belum ada model lokal. Gunakan Impor file GGUF atau unduh model dari Hugging Face.', style: TextStyle(fontSize: 12, color: muted))
      else ...[
        const Text('Model tersimpan', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        for (final model in _localModels) Card(color: panel2, child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          leading: Icon(model['active'] == true ? Icons.check_circle : Icons.memory_outlined, color: model['active'] == true ? Colors.greenAccent : purple),
          title: Text('${model['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          subtitle: Text('${_bytes(model['size'])} · ${model['active'] == true ? 'aktif' : 'tersedia'}\nSHA-256: ${_shortHash(model['sha256'])}', style: const TextStyle(fontSize: 10, color: muted)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (model['active'] == true) const Text('AKTIF', style: TextStyle(fontSize: 9, color: Colors.greenAccent, fontWeight: FontWeight.bold)),
            if (widget.onEditModel != null)
              IconButton(
                tooltip: 'Edit metadata',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_note_outlined, size: 20),
                onPressed: () => widget.onEditModel!('${model['path']}'),
              ),
            if (model['active'] != true)
              PopupMenuButton<String>(
                  onSelected: (action) {
                    final path = '${model['path']}';
                    if (action == 'use') _activateLocalModel(path);
                    if (action == 'delete') _deleteLocalModel(path);
                    if (action == 'rename') _renameLocalModel(path, '${model['name']}');
                    if (action == 'verify') _verifyLocalModel(path);
                    if (action == 'metadata') _showModelMetadata(path);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'use', child: Text('Pakai')),
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'verify', child: Text('Verifikasi SHA-256')),
                    PopupMenuItem(value: 'metadata', child: Text('Lihat metadata')),
                    PopupMenuItem(value: 'delete', child: Text('Hapus')),
                  ],
                ),
          ]),
        )),
      ],
      const SizedBox(height: 8), const Text('Inferensi memerlukan libneuron_llama.so untuk ABI perangkat. Model besar membutuhkan ruang penyimpanan dan RAM yang cukup.', style: TextStyle(fontSize: 11, color: muted)),
    ])),
    if (_localModels.isNotEmpty) _card('Ubah bobot model', 'Kuantisasi, tanam adapter LoRA, dan gabung model. Berjalan di server ModelOps HTTPS (diatur di halaman Latih); hasil disimpan sebagai model baru dan model asli tidak diubah.', icon: Icons.tune, child: FilledButton.icon(onPressed: widget.onOpenPage == null ? null : () => widget.onOpenPage!('Ubah bobot'), icon: const Icon(Icons.tune), label: const Text('Buka Ubah bobot'))),
    _message(),
  ]);

  Widget _hardwarePage() {
    final warnings = ((_health['warnings'] as List?) ?? const []).map((e) => e.toString()).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _card('Device Health Check', 'Periksa RAM, storage, ABI, dan kondisi perangkat sebelum memuat model besar.', icon: Icons.health_and_safety_outlined, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          _metric('RAM bebas', _bytes(_health['availableRam'])),
          _metric('Storage bebas', _bytes(_health['freeStorage'])),
          _metric('CPU', '${_health['cpuCores'] ?? '-'} core'),
          _metric('Android', 'SDK ${_health['sdk'] ?? '-'}'),
        ]),
        const SizedBox(height: 10),
        Text('ABI: ${_health['abi'] ?? 'memuat…'}', style: const TextStyle(fontSize: 11, color: muted)),
        Text('Rekomendasi ukuran model: ${_bytes(_health['recommendedMaxModel'])}', style: const TextStyle(fontSize: 11, color: muted)),
        if (warnings.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final warning in warnings) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('⚠ $warning', style: const TextStyle(color: Colors.orangeAccent, fontSize: 11))),
        ] else if (_health.isNotEmpty) const Text('Perangkat tampak siap untuk pemeriksaan model dasar.', style: TextStyle(color: Colors.greenAccent, fontSize: 11)),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: _busy ? null : () => _loadHealth(), icon: const Icon(Icons.refresh), label: const Text('Periksa ulang')),
      ])),
      _message(),
    ]);
  }

  Widget _metric(String label, String value) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(9)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: muted, fontSize: 10)), const SizedBox(height: 3), Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12))]),
      );

  String _shortHash(dynamic value) {
    final hash = value?.toString() ?? '';
    if (hash.isEmpty) return 'belum tersedia';
    return '${hash.substring(0, math.min(16, hash.length))}…';
  }

  Widget _ragPage() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _card('Dokumen pengetahuan', 'Tambahkan file teks, Markdown, PDF, DOCX, CSV, atau kode (maksimum 25 MB per file). File disalin ke penyimpanan aplikasi.', icon: Icons.storage_outlined, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, children: [FilledButton.icon(onPressed: _busy ? null : _addKnowledge, icon: const Icon(Icons.add), label: const Text('Tambah dokumen')), OutlinedButton.icon(onPressed: _busy ? null : _index, icon: const Icon(Icons.manage_search), label: const Text('Buat / perbarui indeks'))]),
      const SizedBox(height: 10), Text('Status: ${(_rag['files'] as List?)?.length ?? 0} dokumen · ${_rag['chunks'] ?? 0} chunk · RAG ${_rag['enabled'] == true ? 'aktif' : 'nonaktif'}', style: const TextStyle(fontSize: 12, color: muted)),
      const SizedBox(height: 7), if ((_rag['files'] as List?)?.isNotEmpty == true) ...[for (final file in (_rag['files'] as List).take(30)) Text('• ${file.toString().split('/').last}', style: const TextStyle(fontSize: 11, color: Colors.white70))],
      const SizedBox(height: 8), const Text('Embeddings memakai model lokal yang aktif. Jika model tidak mendukung embedding, indeks tidak akan terbentuk.', style: TextStyle(fontSize: 11, color: muted)),
    ])), _message(),
  ]);

  Widget _hfPage() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _card('Hugging Face · Model Hub', 'Pilih repo untuk melihat format, file bobot, dan total ukurannya. Unduh model lengkap mengantrekan semua shard bobot dan file tokenizer/config yang terdeteksi. Token opsional untuk repo gated/privat.', icon: Icons.cloud_download_outlined, child: Column(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(9)),
        child: Text(
          _hfNativeAvailable == true
              ? 'Lokal: runtime llama.cpp tersedia untuk GGUF saja. Safetensors/BIN/ONNX dapat diunduh, tetapi tidak dapat dijalankan langsung.'
              : _hfNativeAvailable == false
                  ? 'Lokal: runtime llama.cpp tidak ada di APK ini. Saat ini tidak ada model yang bisa diinferensikan lokal; GGUF perlu APK dengan libneuron_llama.so. Model Safetensors/BIN/ONNX juga tidak didukung runtime lokal.'
                  : 'Memeriksa runtime lokal…',
          style: TextStyle(fontSize: 11, height: 1.35, color: _hfNativeAvailable == false ? Colors.orangeAccent : muted),
        ),
      ),
      const SizedBox(height: 8),
      TextField(controller: _hfToken, obscureText: true, decoration: const InputDecoration(labelText: 'Token HF (opsional)', hintText: 'hf_…')),
      Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: _busy ? null : () => _run(() async { await Bridge.saveHfToken(_hfToken.text.trim()); setState(() => _status = 'Token disimpan terenkripsi.'); }), child: const Text('Simpan token'))),
      Row(children: [Expanded(child: TextField(controller: _query, onSubmitted: (_) => _searchHf(), decoration: const InputDecoration(labelText: 'Cari model', hintText: 'llama 3 gguf'))), const SizedBox(width: 8), IconButton.filled(onPressed: _busy ? null : _searchHf, icon: const Icon(Icons.search))]),
      Align(alignment: Alignment.centerLeft, child: DropdownButton<String>(value: _hfScope, items: const [DropdownMenuItem(value: 'all', child: Text('Semua format Hugging Face')), DropdownMenuItem(value: 'gguf', child: Text('GGUF siap pakai lokal'))], onChanged: (v) => setState(() => _hfScope = v ?? 'all'))),
      const Align(alignment: Alignment.centerLeft, child: Text('Contoh model penuh (format Hugging Face)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
      const SizedBox(height: 4),
      const Align(alignment: Alignment.centerLeft, child: Text('Ketuk contoh untuk mencari repository tanpa mengetik. File bobot diunduh satu per satu; model non-GGUF belum bisa dijalankan langsung secara lokal.', style: TextStyle(color: muted, fontSize: 10))),
      Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 6, runSpacing: 4, children: [
        for (final example in _hfFullModelExamples.entries) ActionChip(
          label: Text(example.key),
          onPressed: _busy ? null : () {
            _query.text = example.value;
            setState(() => _hfScope = 'all');
            _searchHf();
          },
        ),
      ])),
      const SizedBox(height: 8),
      Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 6, runSpacing: 4, children: [
        DropdownButton<String>(value: _sizeFilter, items: const ['Semua', '≤ 1 GB', '1–3 GB', '3–8 GB', '> 8 GB'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(), onChanged: (v) => setState(() => _sizeFilter = v ?? 'Semua')),
        DropdownButton<String>(value: _quantFilter, items: const ['Semua', 'Q4_K_M', 'Q5_K_M', 'Q8_0', 'F16'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(), onChanged: (v) => setState(() => _quantFilter = v ?? 'Semua')),
      ])),
      if (_localModels.where((m) {
        final q = _query.text.trim().toLowerCase();
        return q.isEmpty || '${m['name']}'.toLowerCase().contains(q) || '${m['sourceRepo'] ?? ''}'.toLowerCase().contains(q);
      }).isNotEmpty) ...[
        const SizedBox(height: 10),
        const Align(alignment: Alignment.centerLeft, child: Text('Model lokal terpasang', style: TextStyle(fontWeight: FontWeight.w700))),
        for (final model in _localModels.where((m) {
          final q = _query.text.trim().toLowerCase();
          return q.isEmpty || '${m['name']}'.toLowerCase().contains(q) || '${m['sourceRepo'] ?? ''}'.toLowerCase().contains(q);
        })) ...[
          Builder(builder: (_) {
            final path = '${model['path']}';
            final update = _localUpdates[path];
            final available = update?['updateAvailable'] == true;
            final repo = '${model['sourceRepo'] ?? ''}';
            return Card(color: panel2, child: ListTile(
              dense: true,
              leading: Icon(model['active'] == true ? Icons.check_circle : Icons.memory_outlined, color: model['active'] == true ? Colors.greenAccent : purple),
              title: Text('${model['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
              subtitle: Text(repo.isEmpty ? '${_bytes(model['size'])} · asal repo belum ditautkan' : '$repo · ${available ? 'Pembaruan tersedia' : 'revision terbaru'}', style: TextStyle(fontSize: 10, color: available ? Colors.orangeAccent : muted)),
              trailing: repo.isEmpty ? const SizedBox.shrink() : IconButton(tooltip: 'Periksa pembaruan', icon: Icon(available ? Icons.system_update_alt : Icons.refresh, color: available ? Colors.orangeAccent : muted), onPressed: _busy ? null : () async {
                try {
                  final result = await Bridge.checkLocalModelUpdate(path);
                  if (!mounted) return;
                  setState(() => _localUpdates[path] = result);
                  if (result['updateAvailable'] == true) {
                    _query.text = repo;
                    _hfScope = 'all';
                    final found = await Bridge.hfSearch(repo, scope: 'all');
                    if (mounted) setState(() { _models = found; _files = []; _repoSelected = null; _status = 'Pembaruan tersedia untuk $repo. Tinjau file sebelum mengunduh; model lama tidak ditimpa otomatis.'; });
                  } else {
                    setState(() => _status = '$repo sudah memakai revision terbaru yang terdeteksi.');
                  }
                } catch (e) {
                  if (mounted) setState(() => _status = 'Pemeriksaan pembaruan gagal: $e');
                }
              }),
            ));
          }),
        ],
      ],
      if (_models.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Align(alignment: Alignment.centerLeft, child: Text('Pilih repository model', style: TextStyle(fontWeight: FontWeight.w700))),
        const SizedBox(height: 4),
        const Text('Buka repo untuk melihat jenis file, ukuran per file, total bobot, dan tombol unduh lengkap.', style: TextStyle(color: muted, fontSize: 10)),
        const SizedBox(height: 6),
        for (final model in _models) Card(
          color: panel2,
          margin: const EdgeInsets.only(bottom: 6),
          child: ExpansionTile(
            key: PageStorageKey('hf-repo-${model['id']}'),
            initiallyExpanded: _repoSelected == model['id'],
            leading: const Icon(Icons.model_training_outlined, color: purple),
            title: Text('${model['id']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            subtitle: Text('Tugas: ${model['pipeline'] ?? 'tidak diketahui'} · ${model['gguf'] == true ? 'GGUF tersedia' : 'GGUF belum terdeteksi'} · ${model['downloads'] ?? 0} unduhan · ${model['likes'] ?? 0} suka', style: const TextStyle(color: muted, fontSize: 10)),
            onExpansionChanged: (open) {
              if (open && !_busy && _repoSelected != model['id']) _selectRepo('${model['id']}');
            },
            children: [
              if (_repoSelected == model['id'] && _files.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Align(alignment: Alignment.centerLeft, child: Text('Memuat file repo…', style: TextStyle(color: muted, fontSize: 11)))),
              if (_repoSelected == model['id'] && _files.isNotEmpty) _fullModelDownloadControl('${model['id']}'),
              if (_repoSelected == model['id']) for (final file in _files.where(_fileVisible)) ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: const Icon(Icons.insert_drive_file_outlined, size: 20, color: blue),
                title: Text('${file['name']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                subtitle: Text('${file['gguf'] == true ? 'GGUF · bisa dipakai lokal' : 'Non-GGUF · perlu konversi'} · ${_bytes(file['size'])}', style: const TextStyle(color: muted, fontSize: 10)),
                trailing: FilledButton.icon(onPressed: _busy || _downloadId != null ? null : () => _download('${model['id']}', '${file['name']}'), icon: const Icon(Icons.download, size: 15), label: Text(file['gguf'] == true ? 'Unduh GGUF' : 'Unduh file', style: const TextStyle(fontSize: 10))),
              ),
            ],
          ),
        ),
      ],
      if (_downloadId != null) ...[
        const SizedBox(height: 10),
        Builder(builder: (_) {
          final total = ((_downloadIsFullModel ? _downloadState['modelTotal'] : _downloadState['total']) as num?)?.toDouble() ?? -1;
          final done = ((_downloadIsFullModel ? _downloadState['modelDone'] : _downloadState['done']) as num?)?.toDouble() ?? 0;
          final fileTotal = (_downloadState['total'] as num?)?.toDouble() ?? -1;
          final fileDone = (_downloadState['done'] as num?)?.toDouble() ?? 0;
          return Column(children: [
            LinearProgressIndicator(value: total > 0 ? (done / total).clamp(0, 1).toDouble() : null),
            const SizedBox(height: 5),
            Row(children: [Expanded(child: Text(_downloadIsFullModel
                ? 'File ${_downloadState['index'] ?? 0}/${_downloadState['count'] ?? 0} · ${_downloadState['file'] ?? 'Menyiapkan…'} · Total ${_bytes(done)} / ${_bytes(total)} · file ini ${_bytes(fileDone)} / ${_bytes(fileTotal)} · ${_rate(_downloadState['speed'])} · ETA ${_eta(_downloadState['eta'])}'
                : '${_downloadState['file'] ?? 'Menyiapkan…'} · ${_bytes(done)} / ${_bytes(total)} · ${_rate(_downloadState['speed'])} · ETA ${_eta(_downloadState['eta'])}', style: const TextStyle(fontSize: 11, color: muted))), TextButton(onPressed: _pauseOrResumeDownload, child: Text(_downloadPaused ? 'Lanjutkan' : 'Jeda')), TextButton(onPressed: _cancelDownload, child: const Text('Batal'))]),
          ]);
        }),
      ],
      if (_downloadHistory.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Align(alignment: Alignment.centerLeft, child: Text('Riwayat download', style: TextStyle(fontWeight: FontWeight.w700))),
        const SizedBox(height: 5),
        for (final item in _downloadHistory.take(10)) ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(_historyIcon('${item['state']}'), color: _historyColor('${item['state']}')), title: Text('${item['file']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)), subtitle: Text('${item['repo']} · ${item['state']}${item['error'].toString().isEmpty ? '' : ' · ${item['error']}' }', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: muted))),
      ],
      const SizedBox(height: 5), const Text('Unduhan memakai WorkManager foreground job, resume dari byte terakhir, menampilkan progres per-byte, dan dapat dibatalkan.', style: TextStyle(fontSize: 11, color: muted)),
    ])), _message(),
  ]);

  Widget _copilotPage() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _card('Copilot konfigurasi', 'Saran dibuat oleh engine aktif. Copilot tidak menulis otomatis: setiap patch harus ditinjau dan diterima per file.', icon: Icons.auto_awesome_outlined, child: Column(children: [
      TextField(controller: _complaint, maxLines: 3, decoration: const InputDecoration(labelText: 'Keluhan / target perbaikan', hintText: 'Jawaban terlalu panjang dan sering mengulang…')),
      TextField(controller: _sample, maxLines: 3, decoration: const InputDecoration(labelText: 'Contoh output (opsional)')),
      const SizedBox(height: 10),
      Align(alignment: Alignment.centerLeft, child: FilledButton.icon(onPressed: _busy ? null : () => _run(() async {
        final result = await Bridge.copilotSuggest(_complaint.text, _sample.text, '');
        setState(() {
          _copilotChanges = ((result['changes'] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
          _reviewedCopilotPaths.clear();
          _status = '${result['reason'] ?? 'Tidak ada alasan'}\n${_copilotChanges.isEmpty ? '\nTidak ada perubahan yang diusulkan.' : ''}';
        });
      }), icon: const Icon(Icons.lightbulb_outline), label: const Text('Minta saran'))),
      if (_copilotChanges.isNotEmpty) ...[
        const Divider(),
        for (final change in _copilotChanges) ...[
          Builder(builder: (context) {
            final path = '${change['path']}';
            final reviewed = _reviewedCopilotPaths.contains(path);
            return Card(color: panel2, child: Padding(padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(path, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              Text('${change['error'] ?? 'Patch valid'}', style: TextStyle(color: change['error'] == null ? Colors.greenAccent : Colors.orangeAccent, fontSize: 11)),
              if (change['error'] == null) ...[
                const SizedBox(height: 8),
                const Text('Sebelum', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
                SelectableText('${change['oldText'] ?? ''}', style: const TextStyle(fontFamily: 'monospace', fontSize: 10)),
                const SizedBox(height: 8),
                const Text('Usulan', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
                SelectableText('${change['newText'] ?? ''}', style: const TextStyle(fontFamily: 'monospace', fontSize: 10)),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: reviewed,
                  title: const Text('Saya sudah meninjau teks sebelum dan usulan', style: TextStyle(fontSize: 11)),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      _reviewedCopilotPaths.add(path);
                    } else {
                      _reviewedCopilotPaths.remove(path);
                    }
                  }),
                ),
                Align(alignment: Alignment.centerRight, child: TextButton(
                  onPressed: _busy || !reviewed ? null : () => _run(() async {
                    await Bridge.copilotApply(path, '${change['oldText']}', '${change['newText']}');
                    setState(() {
                      _copilotChanges.remove(change);
                      _reviewedCopilotPaths.remove(path);
                      _status = 'Patch $path diterapkan.';
                    });
                  }),
                  child: const Text('Terapkan patch yang ditinjau'),
                )),
              ],
            ])));
          }),
        ],
      ],
      const SizedBox(height: 6), const Text('Patch dapat diterapkan dari editor setelah ditinjau. File API key, model, training, dan eval tetap diblokir oleh CopilotAgent.', style: TextStyle(fontSize: 11, color: muted)),
    ])), _message(),
  ]);

  String _bytes(dynamic value) { final n = value is num ? value.toDouble() : 0.0; if (n <= 0) return 'ukuran tidak diketahui'; if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(1)} GB'; return '${(n / 1e6).toStringAsFixed(0)} MB'; }
  String _rate(dynamic value) { final n = value is num ? value.toDouble() : 0.0; return n <= 0 ? '—' : '${_bytes(n)}/s'; }
  String _eta(dynamic value) { final n = value is num ? value.toInt() : -1; if (n < 0) return '—'; if (n < 60) return '${n}s'; return '${n ~/ 60}m'; }
  IconData _historyIcon(String state) => switch (state) { 'succeeded' => Icons.check_circle_outline, 'failed' => Icons.error_outline, 'paused' => Icons.pause_circle_outline, _ => Icons.downloading_outlined };
  Color _historyColor(String state) => switch (state) { 'succeeded' => Colors.greenAccent, 'failed' => Colors.redAccent, 'paused' => Colors.orangeAccent, _ => blue };

  Widget _pendingPage(IconData icon, String title, String detail) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_card(title, detail, icon: icon), _message()]);
}
