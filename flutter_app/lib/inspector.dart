import 'dart:convert';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Inspektur untuk chat/params.json. Setiap perubahan ditulis ulang sebagai teks JSON
/// lewat [onChanged], lalu masuk ke editor dan riwayat undo.
class ParamInspector extends StatelessWidget {
  const ParamInspector({super.key, required this.text, required this.onChanged});

  final String text;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = _decode(text);
    if (p == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'JSON tidak valid. Perbaiki di mode Kode untuk membuka Inspektur.',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _slider(p, 'temperature', 'Temperature', 0.0, 2.0, 'Mengatur variasi jawaban', false),
        _slider(p, 'top_p', 'Top-p', 0.0, 1.0, 'Nucleus sampling', false),
        _slider(p, 'top_k', 'Top-k', 0.0, 200.0, 'Jumlah kandidat token', true),
        _slider(p, 'max_tokens', 'Max tokens', 1.0, 8192.0, 'Batas panjang keluaran', true),
        const SizedBox(height: 4),
        _seed(p),
      ],
    );
  }

  static Map<String, dynamic>? _decode(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  void _set(Map<String, dynamic> p, String key, Object value) {
    p[key] = value;
    onChanged(const JsonEncoder.withIndent('  ').convert(p));
  }

  Widget _slider(Map<String, dynamic> p, String key, String title, double min, double max, String hint, bool isInt) {
    final raw = p[key];
    final n = raw is num ? raw.toDouble().clamp(min, max).toDouble() : min;
    final shown = isInt ? n.round().toString() : n.toStringAsFixed(2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(shown, style: const TextStyle(color: purple)),
        ]),
        Slider(
          value: n,
          min: min,
          max: max,
          onChanged: (v) => _set(p, key, isInt ? v.round() : double.parse(v.toStringAsFixed(2))),
        ),
        Text(hint, style: const TextStyle(color: muted, fontSize: 10)),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _seed(Map<String, dynamic> p) {
    final seed = p['seed'] is num ? (p['seed'] as num).toInt() : 42;
    return Row(children: [
      const Expanded(child: Text('Seed', style: TextStyle(fontWeight: FontWeight.w600))),
      IconButton(
        tooltip: 'Kurangi',
        onPressed: () => _set(p, 'seed', seed - 1),
        icon: const Icon(Icons.remove_circle_outline),
      ),
      Text('$seed', style: const TextStyle(color: purple)),
      IconButton(
        tooltip: 'Tambah',
        onPressed: () => _set(p, 'seed', seed + 1),
        icon: const Icon(Icons.add_circle_outline),
      ),
    ]);
  }
}
