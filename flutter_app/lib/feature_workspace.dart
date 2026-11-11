import 'dart:async';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'bridge.dart';
import 'theme.dart';
import 'training_page.dart';

class FeatureWorkspace extends StatefulWidget {
  const FeatureWorkspace({super.key, required this.page, required this.onLog, required this.onBack});
  final String page;
  final void Function(String level, String message) onLog;
  final VoidCallback onBack;
  @override
  State<FeatureWorkspace> createState() => _FeatureWorkspaceState();
}

class _FeatureWorkspaceState extends State<FeatureWorkspace> {
  final _query = TextEditingController();
  final _repo = TextEditingController();
  final _port = TextEditingController(text: '8080');
  final _serverKey = TextEditingController();
  final _hfToken = TextEditingController();
  final _complaint = TextEditingController();
  final _sample = TextEditingController();
  bool _busy = false;
  String _status = '';
  bool _showServerKey = false;
  List<Map<String, dynamic>> _models = [];
  List<Map<String, dynamic>> _files = [];
  List<Map<String, dynamic>> _localModels = [];
  List<Map<String, dynamic>> _downloadHistory = [];
  Map<String, dynamic> _server = {};
  Map<String, dynamic> _rag = {};
  String? _repoSelected;
  String? _downloadId;
  bool _downloadPaused = false;
  String _sizeFilter = 'Semua';
  String _quantFilter = 'Semua';
  Timer? _downloadPoll;
  Map<String, dynamic> _downloadState = const {};
  Map<String, dynamic> _health = const {};
  List<Map<String, dynamic>> _copilotChanges = [];
  final Set<String> _reviewedCopilotPaths = {};

  @override
  void initState() {
    super.initState();
    if (widget.page == 'Server') _loadServer();
    if (widget.page == 'Data & RAG') _loadRag();
    if (widget.page == 'Model lokal') _loadLocalModels();
    if (widget.page == 'Hardware') _loadHealth();
    if (widget.page == 'Hugging Face') _loadDownloadHistory();
  }

  @override
  void dispose() {
    _downloadPoll?.cancel();
    _query.dispose();
    _repo.dispose();
    _port.dispose();
    _serverKey.dispose();
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

  Future<void> _loadServer() async {
    try {
      final value = await Bridge.serverState();
      if (!mounted) return;
      setState(() {
        _server = value;
        _port.text = '${value['port'] ?? 8080}';
        _serverKey.text = '${value['apiKey'] ?? ''}';
      });
    } catch (e) { if (mounted) setState(() => _status = 'Server belum dapat diakses: $e'); }
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
    final found = await Bridge.hfSearch(_query.text.trim());
    setState(() { _models = found; _files = []; _repoSelected = null; });
    _status = '${found.length} repo GGUF ditemukan';
  });

  Future<void> _selectRepo(String id) async => _run(() async {
    final found = await Bridge.hfFiles(id);
    setState(() { _repo.text = id; _repoSelected = id; _files = found; });
    _status = '${found.length} file GGUF';
  });

  Future<void> _download(String repo, String file) async {
    if (_downloadId != null) return;
    await _run(() async {
      final started = await Bridge.hfStartDownload(repo, file);
      _downloadId = started['id']?.toString();
      if (_downloadId == null) throw Exception('ID unduhan tidak tersedia');
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
      if (status == 'succeeded' && modelPath.isNotEmpty) {
        try {
          await Bridge.activateLocalModel(modelPath);
          await _loadLocalModels();
        } catch (e) {
          if (mounted) setState(() => _status = 'Unduhan selesai, tetapi model belum bisa diaktifkan: $e');
        }
      }
      setState(() => _status = status == 'succeeded' ? 'Unduhan selesai: ${state['path']}' : status == 'cancelled' ? 'Unduhan dibatalkan.' : 'Unduhan gagal: ${state['error']}');
      await _loadDownloadHistory();
    }
  }

  Future<void> _cancelDownload() async {
    final id = _downloadId;
    if (id == null) return;
    await Bridge.hfCancelDownload(id);
    _downloadPoll?.cancel();
    if (mounted) setState(() { _downloadId = null; _status = 'Permintaan pembatalan dikirim.'; });
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

  Future<bool> _confirmHttpExposure() async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Mulai server HTTP lokal?'),
          content: const Text(
              'Server dapat diakses dari perangkat pada interface jaringan yang aktif. Koneksi tidak dienkripsi dan bearer key dapat terlihat oleh pihak lain di jaringan. Lanjutkan hanya pada jaringan tepercaya; jangan gunakan di Wi-Fi publik atau membuka port ke internet.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Batal')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Saya paham, lanjutkan')),
          ],
        ),
      ) ??
      false;

  Future<void> _generateServerKey() async => _run(() async {
    final key = await Bridge.generateServerKey();
    if (key.length < 32) throw Exception('Pembuat API key gagal.');
    setState(() { _serverKey.text = key; _status = 'API key acak baru dibuat. Simpan & mulai untuk menyimpannya secara terenkripsi.'; });
  });

  Future<void> _configureServer() async {
    if (!await _confirmHttpExposure() || !mounted) return;
    await _run(() async {
      final port = int.tryParse(_port.text.trim());
      if (port == null) throw Exception('Port harus berupa angka.');
      await Bridge.saveServer(port, _serverKey.text.trim());
      if (_server['running'] == true) {
        await Bridge.stopServer();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      await Bridge.startServer();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await _loadServer();
      widget.onLog('INFO', 'Server lokal diminta berjalan pada port $port');
    });
  }

  Future<void> _stopServer() async => _run(() async {
    await Bridge.stopServer();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _loadServer();
    widget.onLog('INFO', 'Server lokal dihentikan');
  });

  @override
  Widget build(BuildContext context) {
    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: widget.onBack, icon: const Icon(Icons.arrow_back), label: const Text('Kembali ke Workspace'))),
      switch (widget.page) {
      'Model lokal' => _localPage(),
      'Server' => _serverPage(),
      'Data & RAG' => _ragPage(),
      'Hugging Face' => _hfPage(),
      'Latih' => TrainingPage(onLog: widget.onLog),
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
          trailing: model['active'] == true
              ? const Text('AKTIF', style: TextStyle(fontSize: 9, color: Colors.greenAccent, fontWeight: FontWeight.bold))
              : PopupMenuButton<String>(
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
        )),
      ],
      const SizedBox(height: 8), const Text('Inferensi memerlukan libneuron_llama.so untuk ABI perangkat. Model besar membutuhkan ruang penyimpanan dan RAM yang cukup.', style: TextStyle(fontSize: 11, color: muted)),
    ])), _message(),
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
    ];
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

  Widget _serverPage() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _card('Server OpenAI-compatible', 'Mengekspos API HTTP pada interface jaringan aktif. Server tidak dienkripsi; mulai hanya pada jaringan tepercaya.', icon: Icons.dns_outlined, child: Column(children: [
      TextField(controller: _port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Port (1024–65535)')),
      TextField(
        controller: _serverKey,
        obscureText: !_showServerKey,
        decoration: InputDecoration(
          labelText: 'Bearer API key (minimal 32 karakter)',
          suffixIcon: IconButton(
            tooltip: _showServerKey ? 'Sembunyikan key' : 'Tampilkan key untuk disalin',
            onPressed: () => setState(() => _showServerKey = !_showServerKey),
            icon: Icon(_showServerKey ? Icons.visibility_off : Icons.visibility),
          ),
        ),
      ),
      Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: _busy ? null : _generateServerKey, icon: const Icon(Icons.key), label: const Text('Buat key acak 256-bit'))),
      const SizedBox(height: 12), Wrap(spacing: 8, children: [
        FilledButton.icon(onPressed: _busy ? null : _configureServer, icon: const Icon(Icons.play_arrow), label: const Text('Simpan & mulai')),
        OutlinedButton.icon(onPressed: _busy ? null : _stopServer, icon: const Icon(Icons.stop), label: const Text('Hentikan')),
        TextButton(onPressed: _busy ? null : _loadServer, child: const Text('Segarkan')),
      ]),
      const SizedBox(height: 8), Align(alignment: Alignment.centerLeft, child: Text((_server['running'] == true ? 'Aktif: ${_server['address'] ?? 'menunggu alamat'}' : 'Tidak aktif') + ((_server['error'] == null) ? '' : '\nError: ${_server['error']}'), style: TextStyle(color: _server['running'] == true ? Colors.greenAccent : muted, fontSize: 12))),
      const SizedBox(height: 6), const Text('Sebelum mulai akan tampil konfirmasi keamanan. Gunakan key acak dan jangan bagikan key melalui kanal yang tidak aman. Build release memblokir koneksi HTTP keluar ke API; server HTTP masuk ini tetap hanya untuk jaringan tepercaya.', style: TextStyle(fontSize: 11, color: muted)),
    ])), _message(),
  ]);

  Widget _ragPage() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _card('Dokumen pengetahuan', 'Tambahkan file teks, Markdown, PDF, DOCX, CSV, atau kode (maksimum 25 MB per file). File disalin ke penyimpanan aplikasi.', icon: Icons.storage_outlined, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, children: [FilledButton.icon(onPressed: _busy ? null : _addKnowledge, icon: const Icon(Icons.add), label: const Text('Tambah dokumen')), OutlinedButton.icon(onPressed: _busy ? null : _index, icon: const Icon(Icons.manage_search), label: const Text('Buat / perbarui indeks'))]),
      const SizedBox(height: 10), Text('Status: ${(_rag['files'] as List?)?.length ?? 0} dokumen · ${_rag['chunks'] ?? 0} chunk · RAG ${_rag['enabled'] == true ? 'aktif' : 'nonaktif'}', style: const TextStyle(fontSize: 12, color: muted)),
      const SizedBox(height: 7), if ((_rag['files'] as List?)?.isNotEmpty == true) ...[for (final file in (_rag['files'] as List).take(30)) Text('• ${file.toString().split('/').last}', style: const TextStyle(fontSize: 11, color: Colors.white70))],
      const SizedBox(height: 8), const Text('Embeddings memakai engine yang dipilih. Untuk engine API, pastikan endpoint mendukung /v1/embeddings; jika tidak, indeks tidak akan terbentuk.', style: TextStyle(fontSize: 11, color: muted)),
    ])), _message(),
  ]);

  Widget _hfPage() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _card('Hugging Face · GGUF', 'Cari repo model publik dan unduh satu file GGUF. File hasil unduh akan menjadi model lokal terpilih. Token hanya diperlukan untuk repo gated/privat dan disimpan terenkripsi.', icon: Icons.cloud_download_outlined, child: Column(children: [
      TextField(controller: _hfToken, obscureText: true, decoration: const InputDecoration(labelText: 'Token HF (opsional)', hintText: 'hf_…')),
      Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: _busy ? null : () => _run(() async { await Bridge.saveHfToken(_hfToken.text.trim()); setState(() => _status = 'Token disimpan terenkripsi.'); }), child: const Text('Simpan token'))),
      Row(children: [Expanded(child: TextField(controller: _query, onSubmitted: (_) => _searchHf(), decoration: const InputDecoration(labelText: 'Cari model', hintText: 'llama 3 gguf'))), const SizedBox(width: 8), IconButton.filled(onPressed: _busy ? null : _searchHf, icon: const Icon(Icons.search))]),
      const SizedBox(height: 8),
      Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 6, runSpacing: 4, children: [
        DropdownButton<String>(value: _sizeFilter, items: const ['Semua', '≤ 1 GB', '1–3 GB', '3–8 GB', '> 8 GB'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(), onChanged: (v) => setState(() => _sizeFilter = v ?? 'Semua')),
        DropdownButton<String>(value: _quantFilter, items: const ['Semua', 'Q4_K_M', 'Q5_K_M', 'Q8_0', 'F16'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(), onChanged: (v) => setState(() => _quantFilter = v ?? 'Semua')),
      ])),
      if (_models.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Align(alignment: Alignment.centerLeft, child: Text('Pilih repository model', style: TextStyle(fontWeight: FontWeight.w700))),
        const SizedBox(height: 4),
        const Text('Ketuk baris repository untuk membuka daftar file GGUF di tempat ini. Tidak perlu berpindah halaman.', style: TextStyle(color: muted, fontSize: 10)),
        const SizedBox(height: 6),
        for (final model in _models) Card(
          color: panel2,
          margin: const EdgeInsets.only(bottom: 6),
          child: ExpansionTile(
            key: PageStorageKey('hf-repo-${model['id']}'),
            initiallyExpanded: _repoSelected == model['id'],
            leading: const Icon(Icons.model_training_outlined, color: purple),
            title: Text('${model['id']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            subtitle: Text('Unduhan ${model['downloads'] ?? 0} · likes ${model['likes'] ?? 0}', style: const TextStyle(color: muted, fontSize: 10)),
            onExpansionChanged: (open) {
              if (open && !_busy && _repoSelected != model['id']) _selectRepo('${model['id']}');
            },
            children: [
              if (_repoSelected == model['id'] && _files.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Align(alignment: Alignment.centerLeft, child: Text('Memuat file GGUF…', style: TextStyle(color: muted, fontSize: 11)))),
              if (_repoSelected == model['id']) for (final file in _files.where(_fileVisible)) ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: const Icon(Icons.insert_drive_file_outlined, size: 20, color: blue),
                title: Text('${file['name']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                subtitle: Text('Ukuran: ${_bytes(file['size'])}', style: const TextStyle(color: muted, fontSize: 10)),
                trailing: FilledButton.icon(onPressed: _busy ? null : () => _download('${model['id']}', '${file['name']}'), icon: const Icon(Icons.download, size: 15), label: const Text('Unduh', style: TextStyle(fontSize: 10))),
              ),
            ],
          ),
        ),
      ],
      if (_downloadId != null) ...[
        const SizedBox(height: 10),
        Builder(builder: (_) {
          final total = (_downloadState['total'] as num?)?.toDouble() ?? -1;
          final done = (_downloadState['done'] as num?)?.toDouble() ?? 0;
          return Column(children: [
            LinearProgressIndicator(value: total > 0 ? (done / total).clamp(0, 1).toDouble() : null),
            const SizedBox(height: 5),
            Row(children: [Expanded(child: Text('${_downloadState['file'] ?? 'Menyiapkan…'} · ${_bytes(done)} / ${_bytes(total)} · ${_rate(_downloadState['speed'])} · ETA ${_eta(_downloadState['eta'])}', style: const TextStyle(fontSize: 11, color: muted))), TextButton(onPressed: _pauseOrResumeDownload, child: Text(_downloadPaused ? 'Lanjutkan' : 'Jeda')), TextButton(onPressed: _cancelDownload, child: const Text('Batal'))]),
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
