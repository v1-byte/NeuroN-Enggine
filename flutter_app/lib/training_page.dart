import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'bridge.dart';
import 'theme.dart';

class TrainingPage extends StatefulWidget {
  const TrainingPage({super.key, required this.onLog});
  final void Function(String level, String message) onLog;

  @override
  State<TrainingPage> createState() => _TrainingPageState();
}

class _TrainingPageState extends State<TrainingPage> {
  final _url = TextEditingController();
  final _apiKey = TextEditingController();
  final _baseModel = TextEditingController();
  final _epochs = TextEditingController();
  final _batch = TextEditingController();
  final _learningRate = TextEditingController();
  final _rank = TextEditingController();
  final _alpha = TextEditingController();
  final _jobId = TextEditingController();
  Timer? _pollTimer;
  bool _busy = false;
  bool _keyConfigured = false;
  String _statusText = '';
  String _method = 'LORA';
  String? _datasetPath;
  Map<String, dynamic> _report = const {};
  Map<String, dynamic> _job = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    for (final c in [_url, _apiKey, _baseModel, _epochs, _batch, _learningRate, _rank, _alpha, _jobId]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final response = await Bridge.trainingLoadConfig();
      final cfg = jsonDecode(response['config'] as String) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _url.text = '${cfg['remoteTrainerUrl'] ?? ''}';
        _baseModel.text = '${cfg['baseModel'] ?? ''}';
        _epochs.text = '${cfg['epochs'] ?? 1}';
        _batch.text = '${cfg['batchSize'] ?? 2}';
        _learningRate.text = '${cfg['learningRate'] ?? 0.0002}';
        _rank.text = '${cfg['loraRank'] ?? 8}';
        _alpha.text = '${cfg['loraAlpha'] ?? 16}';
        _datasetPath = (cfg['datasetPath'] as String?)?.isEmpty == true ? null : cfg['datasetPath'] as String?;
        _method = '${cfg['method'] ?? 'LORA'}';
        _keyConfigured = response['apiKeyConfigured'] == true;
        _jobId.text = '${_job['jobId'] ?? ''}';
      });
      if (_datasetPath != null) {
        try {
          final checked = await Bridge.trainingInspectDataset(_datasetPath!, _method);
          if (mounted) {
            setState(() {
              _report = checked;
              _datasetPath = checked['path'] as String? ?? _datasetPath;
            });
          }
        } catch (e) {
          if (mounted) setState(() => _statusText = 'Dataset tersimpan tidak dapat dibaca; pilih ulang berkas. $e');
        }
      }
      final state = await Bridge.trainingState();
      if (mounted && state['jobId'] != null) {
        setState(() {
          _job = state;
          _jobId.text = '${state['jobId']}';
        });
        if (['running', 'connecting'].contains(state['status'])) {
          try {
            await Bridge.trainingReconnect('${state['jobId']}');
            _ensurePolling();
          } catch (_) {
            if (mounted) setState(() => _statusText = 'Job tersimpan. Tekan Sambung untuk mencoba menghubungi server lagi.');
          }
        }
      }
    } catch (e) {
      if (mounted) setState(() => _statusText = 'Gagal memuat konfigurasi training: $e');
    }
  }

  Map<String, dynamic> _config() => {
        'method': _method,
        'target': 'REMOTE_SERVER',
        'baseModel': _baseModel.text.trim(),
        'datasetPath': _datasetPath ?? '',
        'learningRate': double.tryParse(_learningRate.text.trim()) ?? 0.0002,
        'epochs': int.tryParse(_epochs.text.trim()) ?? 1,
        'batchSize': int.tryParse(_batch.text.trim()) ?? 2,
        'loraRank': int.tryParse(_rank.text.trim()) ?? 8,
        'loraAlpha': int.tryParse(_alpha.text.trim()) ?? 16,
        'remoteTrainerUrl': _url.text.trim(),
        'remoteTrainerApiKey': _apiKey.text.trim(),
        'valDatasetPath': '',
        'valRatio': 0.1,
        'splitSeed': 42,
        'onDeviceBinary': 'native:libllamafinetune.so',
        'onDeviceArgs': '--model-base {base} --train-data {train} --lora-out {out} --epochs {epochs} --adam-iter {iters} --lora-r {rank} --lora-alpha {alpha} --threads {threads} --ctx-size {ctx}',
        'onDeviceLossRegex': r'loss[=: ]+([0-9]+(?:\.[0-9]+)?)',
        'onDeviceMaxSteps': 300,
      };

  Future<void> _withBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _statusText = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _statusText = 'Gagal: $e');
      widget.onLog('ERROR', 'Training: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async => _withBusy(() async {
        if (_url.text.trim().isEmpty) throw Exception('Isi URL remote trainer.');
        if (_baseModel.text.trim().isEmpty) throw Exception('Isi ID model dasar.');
        await Bridge.trainingSaveConfig(_config());
        _apiKey.clear();
        final info = await Bridge.trainingLoadConfig();
        if (mounted) {
          setState(() {
            _keyConfigured = info['apiKeyConfigured'] == true;
            _statusText = 'Konfigurasi tersimpan. API key disimpan terenkripsi dan tidak dimasukkan ke file proyek.';
          });
        }
        widget.onLog('INFO', 'Konfigurasi training remote disimpan');
      });

  Future<void> _pickDataset() async {
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jsonl', 'json', 'csv'],
      withData: false,
    );
    final path = selected?.files.single.path;
    if (path == null) {
      if (selected != null && mounted) setState(() => _statusText = 'Pemilih berkas tidak memberikan path berkas yang dapat dibaca.');
      return;
    }
    await _withBusy(() async {
      final report = await Bridge.trainingInspectDataset(path, _method);
      if (!mounted) return;
      setState(() {
        _datasetPath = report['path'] as String?;
        _report = report;
      });
      if (report['ok'] == true) {
        await Bridge.trainingSaveConfig(_config());
        setState(() => _statusText = 'Dataset valid dan tersimpan di penyimpanan privat aplikasi.');
        widget.onLog('INFO', 'Dataset training tervalidasi: ${report['validRecords']} record');
      } else {
        setState(() => _statusText = 'Dataset memiliki ${report['errorCount']} kesalahan. Perbaiki data sebelum memulai training.');
      }
    });
  }

  Future<void> _start() async => _withBusy(() async {
        if (_report['ok'] != true || _datasetPath == null) throw Exception('Pilih dan validasi dataset yang bersih terlebih dahulu.');
        if (_url.text.trim().isEmpty || _baseModel.text.trim().isEmpty) throw Exception('Isi URL trainer dan ID model dasar.');
        await Bridge.trainingSaveConfig(_config());
        _apiKey.clear();
        final response = await Bridge.trainingStart();
        final id = '${response['jobId'] ?? ''}';
        if (id.isEmpty) throw Exception('Server tidak mengembalikan ID job.');
        if (!mounted) return;
        setState(() {
          _jobId.text = id;
          _job = {'jobId': id, 'status': 'running', 'step': 0, 'total': 0, 'logs': const []};
          _statusText = 'Training dimulai. ID job: $id';
        });
        _ensurePolling();
        widget.onLog('INFO', 'Training dimulai, job $id');
      });

  Future<void> _reconnect() async => _withBusy(() async {
        final id = _jobId.text.trim();
        if (id.isEmpty) throw Exception('Masukkan ID job untuk menyambung.');
        await Bridge.trainingReconnect(id);
        if (!mounted) return;
        setState(() {
          _job = {'jobId': id, 'status': 'connecting', 'logs': const []};
          _statusText = 'Menyambungkan ke job $id…';
        });
        _ensurePolling();
      });

  void _ensurePolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    _poll();
  }

  Future<void> _poll() async {
    try {
      final state = await Bridge.trainingState();
      if (!mounted) return;
      setState(() {
        _job = state;
        if (state['jobId'] != null) _jobId.text = '${state['jobId']}';
      });
      if (!['running', 'connecting', 'cancelling'].contains(state['status'])) _pollTimer?.cancel();
    } catch (e) {
      if (mounted) setState(() => _statusText = 'Tidak dapat membaca progres: $e');
    }
  }

  Future<void> _cancel() async => _withBusy(() async {
        final id = '${_job['jobId'] ?? _jobId.text}'.trim();
        if (id.isEmpty) throw Exception('Tidak ada job aktif.');
        await Bridge.trainingCancel(id);
        await _poll();
        if (mounted) setState(() => _statusText = 'Permintaan pembatalan dikirim ke server.');
        _pollTimer?.cancel();
        widget.onLog('INFO', 'Pembatalan training diminta untuk job $id');
      });

  Future<void> _download(bool gguf) async => _withBusy(() async {
        final id = '${_job['jobId'] ?? _jobId.text}'.trim();
        if (id.isEmpty) throw Exception('ID job tidak tersedia.');
        final result = await Bridge.trainingDownloadAdapter(id, gguf: gguf);
        if (!mounted) return;
        setState(() => _statusText = gguf
            ? 'LoRA diunduh dan dipasang untuk model berikutnya: ${result['path']}'
            : 'Adapter ZIP disimpan: ${result['path']}');
        widget.onLog('INFO', 'Adapter training diunduh: ${result['path']}');
      });

  Widget _field(String label, TextEditingController controller,
      {TextInputType? keyboardType, String? hint, bool secret = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: secret,
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
      );

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

  Widget _datasetCard() {
    final ok = _report['ok'] == true;
    final errors = (_report['errors'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    final preview = (_report['preview'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    return _card('Dataset', _datasetPath ?? 'Belum ada dataset dipilih.', icon: Icons.table_rows_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(onPressed: _busy ? null : _pickDataset, icon: const Icon(Icons.upload_file), label: const Text('Pilih & validasi')),
            DropdownButton<String>(
              value: _method,
              items: const [
                DropdownMenuItem(value: 'LORA', child: Text('LoRA · sederhana')),
                DropdownMenuItem(value: 'QLORA', child: Text('QLoRA · hemat VRAM')),
              ],
              onChanged: _busy ? null : (value) async {
                if (value == null) return;
                setState(() => _method = value);
                if (_datasetPath != null) {
                  await _withBusy(() async {
                    final report = await Bridge.trainingInspectDataset(_datasetPath!, value);
                    if (mounted) setState(() => _report = report);
                  });
                }
              },
            ),
          ]),
          if (_report.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('${_report['validRecords'] ?? 0}/${_report['totalRecords'] ?? 0} record valid · ${_report['errorCount'] ?? 0} kesalahan',
                style: TextStyle(color: ok ? Colors.greenAccent : Colors.orangeAccent, fontWeight: FontWeight.w600)),
            for (final item in errors.take(6)) Text('• $item', style: const TextStyle(color: Colors.orangeAccent, fontSize: 11)),
            for (final item in preview.take(3)) Text('Pratinjau: $item', style: const TextStyle(color: muted, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ]));
  }

  Widget _jobCard() {
    final status = '${_job['status'] ?? 'idle'}';
    final active = ['running', 'connecting', 'cancelling'].contains(status);
    final done = status == 'done';
    final step = (_job['step'] as num?)?.toDouble() ?? 0;
    final total = (_job['total'] as num?)?.toDouble() ?? 0;
    final progress = total > 0 ? (step / total).clamp(0, 1).toDouble() : null;
    final logs = (_job['logs'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    return _card('Job training', 'Status: $status${_job['error'] == null ? '' : ' · ${_job['error']}'}', icon: Icons.school_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _field('ID job (untuk sambung kembali)', _jobId),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(onPressed: _busy || active ? null : _start, icon: const Icon(Icons.play_arrow), label: const Text('Mulai training')),
            OutlinedButton.icon(onPressed: _busy || active ? null : _reconnect, icon: const Icon(Icons.link), label: const Text('Sambung')),
            TextButton.icon(onPressed: _busy || !active ? null : _cancel, icon: const Icon(Icons.stop), label: const Text('Stop')),
          ]),
          if (active) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress),
            Text(total > 0 ? 'Langkah ${step.toInt()} / ${total.toInt()}' : 'Menunggu progres dari server…', style: const TextStyle(color: muted, fontSize: 11)),
          ],
          if (_job['loss'] != null) Text('Loss: ${_job['loss']}', style: const TextStyle(color: muted, fontSize: 12)),
          if (done) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(onPressed: _busy ? null : () => _download(false), icon: const Icon(Icons.archive_outlined), label: const Text('Unduh ZIP')),
              OutlinedButton.icon(onPressed: _busy || _method == 'FULL_FINETUNE' || _method == 'DPO' ? null : () => _download(true), icon: const Icon(Icons.downloading), label: const Text('Unduh & pakai LoRA GGUF')),
            ]),
          ],
          if (logs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(width: double.infinity, constraints: const BoxConstraints(maxHeight: 200), padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: panel2, borderRadius: BorderRadius.circular(8)),
              child: SingleChildScrollView(child: SelectableText(logs.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: muted)))),
          ],
        ]));
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _card('Training sederhana', 'Pilih dataset JSONL/CSV, isi server dan model dasar, lalu jalankan LoRA/QLoRA. Training berjalan di server NeuroN Trainer, bukan di perangkat ini.', icon: Icons.school_outlined,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _field('URL server trainer', _url, hint: 'https://host.example atau http://IP:PORT'),
              _field('API key server (disimpan terenkripsi)', _apiKey, hint: _keyConfigured ? 'Key sudah tersimpan; kosongkan untuk mempertahankan' : 'Opsional sesuai konfigurasi server', secret: true),
              _field('Model dasar (ID repo / nama model di server)', _baseModel),
              DropdownButtonFormField<String>(
                value: _method,
                decoration: const InputDecoration(labelText: 'Metode'),
                items: const [
                  DropdownMenuItem(value: 'LORA', child: Text('LoRA · sederhana')),
                  DropdownMenuItem(value: 'QLORA', child: Text('QLoRA · hemat VRAM')),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  setState(() => _method = value);
                  if (_datasetPath != null) {
                    final report = await Bridge.trainingInspectDataset(_datasetPath!, value);
                    if (mounted) setState(() => _report = report);
                  }
                },
              ),
              const SizedBox(height: 8),
              _field('Epoch', _epochs, keyboardType: TextInputType.number),
              _field('Batch size', _batch, keyboardType: TextInputType.number),
              _field('Learning rate', _learningRate, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
              _field('LoRA rank', _rank, keyboardType: TextInputType.number, hint: '8'),
              _field('LoRA alpha', _alpha, keyboardType: TextInputType.number, hint: '16'),
              Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(onPressed: _busy ? null : _save, icon: const Icon(Icons.save_outlined), label: const Text('Simpan konfigurasi'))),
              const SizedBox(height: 8),
              const Text('Perhatian: training mengunggah dataset dan nama model ke server yang dikonfigurasi. Hindari data sensitif; gunakan HTTPS untuk rilis.', style: TextStyle(color: muted, fontSize: 11, height: 1.35)),
            ])),
        _datasetCard(),
        _jobCard(),
        if (_statusText.isNotEmpty) Card(color: panel2, child: Padding(padding: const EdgeInsets.all(12), child: SelectableText(_statusText, style: const TextStyle(fontSize: 12)))),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
      ]);
}
