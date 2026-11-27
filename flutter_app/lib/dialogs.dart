import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bridge.dart';
import 'privacy_dialog.dart';
import 'theme.dart';

Widget _engineRow(IconData icon, String label, String value, {Color color = muted}) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: muted, fontSize: 11)),
            Text(value, style: const TextStyle(fontSize: 13)),
          ]),
        ),
      ],
    );

/// Dialog Pengaturan: hanya mesin lokal (llama.cpp). Tidak ada Base URL, API key, atau model online.
Future<void> showEngineDialog(BuildContext context, EngineSettings current) =>
    showDialog<void>(context: context, builder: (ctx) => _EngineDialog(current: current));

class _EngineDialog extends StatefulWidget {
  const _EngineDialog({required this.current});
  final EngineSettings current;

  @override
  State<_EngineDialog> createState() => _EngineDialogState();
}

class _EngineDialogState extends State<_EngineDialog> {
  bool? _ragInChat; // null = sedang dimuat

  @override
  void initState() {
    super.initState();
    Bridge.ragInChat().then((v) {
      if (mounted) setState(() => _ragInChat = v);
    }).catchError((Object _) {
      if (mounted) setState(() => _ragInChat = false);
    });
  }

  Future<void> _setRag(bool value) async {
    setState(() => _ragInChat = value);
    try {
      await Bridge.setRagInChat(value);
    } catch (_) {
      if (mounted) setState(() => _ragInChat = !value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.current;
    final hasModel = current.modelPath.isNotEmpty;
    final name = hasModel ? current.modelPath.split('/').last : 'Belum ada model aktif';
    return AlertDialog(
      title: const Text('Pengaturan'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Mesin lokal (llama.cpp)', style: TextStyle(color: purple)),
              const SizedBox(height: 12),
              _engineRow(Icons.memory_outlined, 'Model aktif', name),
              const SizedBox(height: 10),
              _engineRow(
                current.nativeAvailable ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                'Runtime native',
                current.nativeAvailable ? 'Tersedia' : 'Belum tersedia di build ini',
                color: current.nativeAvailable ? green : Colors.orangeAccent,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('RAG di chat', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  'Mati secara bawaan selama pengujian awal. Nyalakan setelah chat tanpa RAG berjalan baik.',
                  style: TextStyle(fontSize: 11, color: muted),
                ),
                value: _ragInChat ?? false,
                onChanged: _ragInChat == null ? null : _setRag,
              ),
              const SizedBox(height: 4),
              const Text(
                'Chat hanya memakai model GGUF di perangkat ini. Tidak ada koneksi ke API atau model online; '
                'konfigurasi API lama, bila ada, diabaikan. '
                'Unduh atau impor model lewat Library dan Import.',
                style: TextStyle(color: muted, fontSize: 11, height: 1.4),
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(backgroundColor: blue),
          child: const Text('Tutup'),
        ),
      ],
    );
  }
}

/// Dialog Fitur: tool calling (BuiltinTools) dan guardrail (kata dan regex).
/// [log] menerima pesan untuk panel Log; hasil simpan ditampilkan sebagai snackbar.
Future<void> showFeaturesDialog(
  BuildContext context,
  FeatureState initial,
  void Function(String level, String text) log,
) async {
  var tools = initial.tools;
  final words = TextEditingController(text: initial.words.join('\n'));
  final regex = TextEditingController(text: initial.regex.join('\n'));

  void snack(BuildContext ctx, String text) {
    ScaffoldMessenger.of(ctx)
      ..clearSnackBars()
      ..showSnackBar(
          SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
  }

  List<String> lines(String s) =>
      s.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Fitur'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Tool calling',
                      style: TextStyle(fontSize: 13)),
                  subtitle: const Text(
                    'current_time dan calculate, dijalankan di HP',
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                  value: tools,
                  onChanged: (v) async {
                    setLocal(() => tools = v);
                    try {
                      await Bridge.setTools(v);
                      log('INFO', 'Tool calling ${v ? 'aktif' : 'nonaktif'}');
                    } catch (e) {
                      setLocal(() => tools = !v);
                      log('ERROR', 'Gagal mengubah tool calling: $e');
                      if (ctx.mounted) snack(ctx, 'Gagal menyimpan fitur');
                    }
                  },
                ),
                const SizedBox(height: 8),
                const Text('Guardrail', style: TextStyle(color: purple)),
                const SizedBox(height: 6),
                TextField(
                  controller: words,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                      labelText: 'Kata terlarang (satu per baris)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: regex,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                      labelText: 'Pola regex (satu per baris)'),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Teks yang cocok diblokir pada input pengguna dan pada jawaban model.',
                  style: TextStyle(color: muted, fontSize: 10),
                ),
                const SizedBox(height: 14),
                const Text('Privasi model', style: TextStyle(color: purple)),
                const SizedBox(height: 6),
                const Text(
                  'Pilih model lokal yang terpasang, ambil privacy.json dari repo asalnya, edit, lalu simpan dan pakai.',
                  style: TextStyle(color: muted, fontSize: 10),
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  icon: const Icon(Icons.privacy_tip_outlined, size: 18),
                  label: const Text('Edit privasi model'),
                  onPressed: () async {
                    final changed = await showPrivacyDialog(ctx, log);
                    if (!changed) return;
                    try {
                      final f = await Bridge.loadFeatures();
                      words.text = f.words.join('\n');
                      regex.text = f.regex.join('\n');
                    } catch (_) {}
                  },
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.code, size: 18),
                  label: const Text('Editor JSON mode chat'),
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await showFeaturesJsonDialog(context, log);
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Tutup')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: blue),
            onPressed: () async {
              try {
                await Bridge.saveGuardrails(
                    lines(words.text), lines(regex.text));
                log('INFO', 'Guardrail disimpan');
                if (ctx.mounted) snack(ctx, 'Guardrail disimpan');
              } catch (e) {
                final msg =
                    e is PlatformException ? (e.message ?? e.code) : '$e';
                log('ERROR', 'Guardrail gagal: $msg');
                if (ctx.mounted) snack(ctx, 'Guardrail tidak valid');
              }
            },
            child: const Text('Simpan guardrail'),
          ),
        ],
      ),
    ),
  );

  Future<void>.delayed(const Duration(milliseconds: 400), () {
    words.dispose();
    regex.dispose();
  });
}

/// Editor langsung untuk features/features.json; hasil divalidasi dan dipakai proyek/runtime.
Future<void> showFeaturesJsonDialog(
  BuildContext context,
  void Function(String level, String text) log,
) async {
  final controller = TextEditingController();
  String? loadError;
  try {
    final raw = await Bridge.read('features/features.json');
    controller.text = JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } catch (e) {
    loadError = e is PlatformException ? (e.message ?? e.code) : '$e';
  }

  void snack(BuildContext ctx, String text) {
    ScaffoldMessenger.of(ctx)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
          content: Text(text), behavior: SnackBarBehavior.floating));
  }

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('JSON fitur & mode chat'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (loadError != null) ...[
                Text('Gagal memuat konfigurasi: $loadError',
                    style: const TextStyle(color: Colors.orangeAccent)),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: controller,
                enabled: loadError == null,
                minLines: 12,
                maxLines: 20,
                keyboardType: TextInputType.multiline,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'features/features.json',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'responseMode menerima "private" atau "open". Private mendorong model agar tidak mengulang rahasia; open mendorong jawaban yang luas. Mode ini hanya instruksi untuk model, bukan enkripsi. Guardrail tetap aktif pada kedua mode, dan open tidak menjamin semua permintaan akan dijawab.',
                style: TextStyle(color: muted, fontSize: 11, height: 1.4),
              ),
              const SizedBox(height: 6),
              const Text(
                'Runtime chat Flutter saat ini menerapkan responseMode, tools, dan guardrail. visionEnabled/mmprojPath serta TTS/STT/voiceLanguage masih hanya tersimpan; pengaturan itu belum mengaktifkan fitur vision atau audio di chat Flutter. Berkas ini berbeda dari privacy.json per-model.',
                style: TextStyle(color: muted, fontSize: 11, height: 1.4),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Batal'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: blue),
          onPressed: loadError != null
              ? null
              : () async {
                  try {
                    final decoded = jsonDecode(controller.text);
                    if (decoded is! Map<String, dynamic>) {
                      throw const FormatException('Akar JSON harus berupa objek.');
                    }
                    const fields = {
                      'tools',
                      'visionEnabled',
                      'mmprojPath',
                      'ttsEnabled',
                      'sttEnabled',
                      'voiceLanguage',
                      'responseMode',
                      'guardrailRegex',
                      'guardrailBlockedWords',
                    };
                    final unknown = decoded.keys.where((key) => !fields.contains(key));
                    if (unknown.isNotEmpty) {
                      throw FormatException(
                          'Field tidak dikenal: ${unknown.join(', ')}');
                    }
                    final mode = decoded['responseMode'];
                    if (decoded.containsKey('responseMode') &&
                        mode != 'private' &&
                        mode != 'open') {
                      throw const FormatException('responseMode harus "private" atau "open".');
                    }
                    await Bridge.write(
                      'features/features.json',
                      JsonEncoder.withIndent('  ').convert(decoded),
                    );
                    final unavailable = <String>[];
                    final mmprojPath = decoded['mmprojPath'];
                    if (decoded['visionEnabled'] == true ||
                        (mmprojPath is String && mmprojPath.trim().isNotEmpty)) {
                      unavailable.add('vision lokal/mmproj');
                    }
                    if (decoded['ttsEnabled'] == true ||
                        decoded['sttEnabled'] == true) {
                      unavailable.add('TTS/STT');
                    }
                    final saveMessage = unavailable.isEmpty
                        ? 'JSON disimpan; responseMode dan guardrail diterapkan.'
                        : 'JSON disimpan, tetapi ${unavailable.join(' dan ')} belum aktif di chat Flutter.';
                    log('INFO', 'Konfigurasi features/features.json disimpan');
                    if (ctx.mounted) {
                      snack(ctx, saveMessage);
                      Navigator.pop(ctx);
                    }
                  } catch (e) {
                    final message = e is PlatformException
                        ? (e.message ?? e.code)
                        : e is FormatException
                            ? e.message
                            : '$e';
                    log('ERROR', 'JSON fitur tidak valid: $message');
                    if (ctx.mounted) snack(ctx, 'JSON tidak valid: $message');
                  }
                },
          child: const Text('Simpan & terapkan'),
        ),
      ],
    ),
  );

  controller.dispose();
}
