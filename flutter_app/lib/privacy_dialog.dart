import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bridge.dart';
import 'theme.dart';

String _err(Object e) => e is PlatformException ? (e.message ?? e.code) : '$e';

String _mb(num bytes) => '${(bytes / 1000000).toStringAsFixed(0)} MB';

/// Editor privasi per model lokal.
///
/// Alurnya sengaja berurutan supaya jelas file mana yang diubah:
/// 1. pilih model yang terpasang (terunduh, terimpor, atau aktif),
/// 2. baca kartu info: nama file yang diedit, lokasi, repo asal unduhan, status model,
/// 3. ambil privacy.json dari repo asal (atau pakai salinan lokal), edit,
/// 4. Simpan (hanya menyimpan ke file model itu) atau Simpan & pakai (juga masuk guardrail; hanya model aktif).
///
/// Mengembalikan true bila guardrail berubah.
Future<bool> showPrivacyDialog(
  BuildContext context,
  void Function(String level, String text) log,
) async {
  var models = <Map<String, dynamic>>[];
  String? selected;
  var loading = true;
  var busy = false;
  var dirty = false;
  var guardrailChanged = false;
  var exists = false;
  var status = '';
  var source = '';
  var fileName = '';
  final text = TextEditingController();

  StateSetter? setLocalRef;
  BuildContext? dialogCtx;
  void refresh() {
    if (dialogCtx != null && dialogCtx!.mounted) setLocalRef?.call(() {});
  }

  Map<String, dynamic>? current() {
    for (final m in models) {
      if (m['path'] == selected) return m;
    }
    return null;
  }

  Future<void> loadModel(String path) async {
    busy = true;
    refresh();
    try {
      final r = await Bridge.privacyLoad(path);
      text.text = r['text'] as String? ?? '';
      exists = r['exists'] == true;
      source = r['source'] as String? ?? '';
      fileName = r['file'] as String? ?? '';
      dirty = false;
      status = exists
          ? 'Salinan lokal dimuat. Edit lalu simpan.'
          : 'Belum ada salinan untuk model ini. Tekan "Ambil dari $source".';
    } catch (e) {
      status = 'Gagal memuat: ${_err(e)}';
    }
    busy = false;
    refresh();
  }

  Future<void> init() async {
    try {
      models = await Bridge.privacyModels();
      if (models.isNotEmpty) {
        final pick = models.firstWhere((m) => m['active'] == true,
            orElse: () => models.first);
        selected = pick['path'] as String;
      }
    } catch (e) {
      status = 'Gagal memuat daftar model: ${_err(e)}';
    }
    loading = false;
    refresh();
    if (selected != null) await loadModel(selected!);
  }

  Future<bool> confirmDiscard(BuildContext ctx) async {
    if (!dirty) return true;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('Buang perubahan?'),
        content: const Text(
            'Privasi model yang sedang dibuka punya perubahan yang belum disimpan.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Kembali')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Buang')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> fetch() async {
    final path = selected;
    if (path == null) return;
    busy = true;
    refresh();
    try {
      final r = await Bridge.privacyFetch(path);
      text.text = r['text'] as String? ?? '';
      dirty = true;
      status =
          'Diambil dari ${r['source']}. Tinjau dan edit, lalu tekan Simpan.';
      log('INFO', 'privacy.json diambil dari ${r['source']}');
    } catch (e) {
      status = 'Gagal mengambil: ${_err(e)}';
      log('ERROR', status);
    }
    busy = false;
    refresh();
  }

  Future<void> save(bool use) async {
    final path = selected;
    if (path == null) return;
    busy = true;
    refresh();
    try {
      final r = await Bridge.privacyApply(path, text.text, use: use);
      dirty = false;
      exists = true;
      if (r.used) {
        guardrailChanged = true;
        status =
            'Disimpan ke ${r.file} dan dipakai. Guardrail kini berisi ${r.words.length} kata dan ${r.regex.length} regex.';
      } else {
        status =
            'Disimpan ke ${r.file}. Belum dipakai di guardrail.';
      }
      if (r.warnings.isNotEmpty) status += '\n${r.warnings.join('\n')}';
      log('INFO', status.split('\n').first);
      for (final w in r.warnings) {
        log('WARN', w);
      }
    } catch (e) {
      status = 'Gagal: ${_err(e)}';
      log('ERROR', status);
    }
    busy = false;
    refresh();
  }

  init();

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        setLocalRef = setLocal;
        dialogCtx = ctx;
        final m = current();
        final isActive = m?['active'] == true;
        return AlertDialog(
          title: const Text('Edit privasi model'),
          content: SizedBox(
            width: 420,
            child: loading
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : models.isEmpty
                    ? const Text(
                        'Belum ada model lokal. Unduh atau impor model GGUF dulu di Library atau Import.',
                        style: TextStyle(color: muted, fontSize: 12),
                      )
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DropdownButtonFormField<String>(
                              isExpanded: true,
                              value: selected,
                              decoration: const InputDecoration(
                                  labelText: '1 · Pilih model yang diedit'),
                              items: [
                                for (final mm in models)
                                  DropdownMenuItem<String>(
                                    value: mm['path'] as String,
                                    child: Text(
                                      '${mm['name']}${mm['active'] == true ? '  • aktif' : ''}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: busy
                                  ? null
                                  : (v) async {
                                      if (v == null || v == selected) return;
                                      if (!await confirmDiscard(ctx)) return;
                                      selected = v;
                                      refresh();
                                      await loadModel(v);
                                    },
                            ),
                            const SizedBox(height: 8),
                            if (m != null)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  border: Border.all(color: muted),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('File yang akan diedit',
                                        style: TextStyle(
                                            color: purple, fontSize: 11)),
                                    const SizedBox(height: 4),
                                    SelectableText(
                                      fileName.isEmpty
                                          ? '${m['name']}.privacy.json'
                                          : fileName,
                                      style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 12),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Model: ${m['name']} (${_mb((m['size'] as num?) ?? 0)})\n'
                                      'Status model: ${isActive ? 'aktif, bisa dipakai di guardrail' : 'terpasang, belum aktif'}\n'
                                      'Disimpan di: penyimpanan model NeuroN, di samping file model\n'
                                      'Sumber unduhan: ${source.isEmpty ? m['source'] : source}\n'
                                      'Salinan lokal: ${exists ? 'sudah ada' : 'belum ada'}',
                                      style: const TextStyle(
                                          color: muted, fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                const Expanded(
                                  child: Text('2 · Ambil dan edit',
                                      style: TextStyle(color: purple)),
                                ),
                                if (dirty)
                                  const Text('● belum disimpan',
                                      style: TextStyle(
                                          color: Colors.orange,
                                          fontSize: 11)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            OutlinedButton(
                              onPressed: busy ? null : fetch,
                              child: Text(
                                  'Ambil dari ${source.isEmpty ? (m?['source'] ?? 'repo') : source}'),
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: text,
                              enabled: !busy,
                              minLines: 5,
                              maxLines: 12,
                              onChanged: (_) {
                                if (!dirty) {
                                  dirty = true;
                                  refresh();
                                }
                              },
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 12),
                              decoration: const InputDecoration(
                                  labelText: 'privacy.json (JSON)'),
                            ),
                            const SizedBox(height: 10),
                            const Text('3 · Simpan',
                                style: TextStyle(color: purple)),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                OutlinedButton(
                                  onPressed: busy ? null : () => save(false),
                                  child: const Text('Simpan saja'),
                                ),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: blue),
                                  onPressed: (busy || !isActive)
                                      ? null
                                      : () => save(true),
                                  child: const Text('Simpan & pakai'),
                                ),
                              ],
                            ),
                            if (!isActive)
                              const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: Text(
                                  'Untuk memakai di guardrail, aktifkan model ini dulu di Library.',
                                  style: TextStyle(
                                      color: muted, fontSize: 10),
                                ),
                              ),
                            if (status.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(status,
                                    style: const TextStyle(fontSize: 12)),
                              ),
                          ],
                        ),
                      ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (!await confirmDiscard(ctx)) return;
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Tutup'),
            ),
          ],
        );
      },
    ),
  );

  Future<void>.delayed(const Duration(milliseconds: 400), text.dispose);
  return guardrailChanged;
}
