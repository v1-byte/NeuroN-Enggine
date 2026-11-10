import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bridge.dart';
import 'theme.dart';

/// Dialog Pengaturan engine API. Mengembalikan nilai baru bila disimpan, null bila dibatalkan.
/// Penyimpanan dilakukan pemanggil lewat Bridge.saveEngine.
Future<EngineSettings?> showEngineDialog(
    BuildContext context, EngineSettings current) async {
  final url = TextEditingController(text: current.baseUrl);
  final model = TextEditingController(text: current.model);
  final key = TextEditingController(text: current.apiKey);

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Pengaturan'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Engine API (OpenAI-compatible)',
                  style: TextStyle(color: purple)),
              const SizedBox(height: 8),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'http://192.168.1.10:11434'),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: url,
                builder: (context, value, _) {
                  if (!value.text.trim().toLowerCase().startsWith('http://')) {
                    return const SizedBox.shrink();
                  }
                  return Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: const Color(0xFF482B20),
                        borderRadius: BorderRadius.circular(9)),
                    child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: Colors.orangeAccent, size: 18),
                          SizedBox(width: 8),
                          Expanded(
                              child: Text(
                                  'HTTP tidak mengenkripsi lalu lintas. API key dan isi chat dapat terlihat di jaringan. Gunakan HTTPS kecuali endpoint LAN tepercaya memang memerlukan HTTP.',
                                  style: TextStyle(fontSize: 11, height: 1.4))),
                        ]),
                  );
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: model,
                decoration: const InputDecoration(
                    labelText: 'Model', hintText: 'llama3.2'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: key,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'API key (kosongkan bila tidak perlu)'),
              ),
              const SizedBox(height: 6),
              const Text(
                'Kunci disimpan terenkripsi di perangkat, tidak ditulis ke project.json.',
                style: TextStyle(color: muted, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(backgroundColor: blue),
          child: const Text('Simpan'),
        ),
      ],
    ),
  );

  final result = saved == true
      ? EngineSettings(
          baseUrl: url.text.trim(),
          model: model.text.trim(),
          apiKey: key.text.trim())
      : null;
  // Dispose tertunda: rute dialog masih beranimasi keluar dan masih membaca controller.
  Future<void>.delayed(const Duration(milliseconds: 400), () {
    url.dispose();
    model.dispose();
    key.dispose();
  });
  return result;
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
