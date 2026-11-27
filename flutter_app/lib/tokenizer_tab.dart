import 'package:flutter/material.dart';

import 'bridge.dart';
import 'errors.dart';
import 'theme.dart';
import 'tokenizer_logic.dart';

/// Tab Tokenizer: ringkasan key `tokenizer.*`, pemeriksaan kewajaran, teks token khusus, dan
/// penjelajah daftar token per halaman. Hanya baca; mengubah ID token khusus lewat tab Metadata.
class TokenizerPanel extends StatefulWidget {
  const TokenizerPanel({super.key, required this.path, this.onLog});

  final String path;
  final void Function(String level, String message)? onLog;

  @override
  State<TokenizerPanel> createState() => _TokenizerPanelState();
}

class _TokenizerPanelState extends State<TokenizerPanel> {
  static const _page = 100;
  static const _tokensKey = 'tokenizer.ggml.tokens';

  final _filter = TextEditingController();
  final _jump = TextEditingController();
  TokenizerInfo? _info;
  bool _loading = true;
  String? _error;
  final Map<int, String> _specialText = {};

  int _offset = 0;
  List<String> _items = const [];
  bool _pageLoading = false;
  String? _pageError;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _filter.dispose();
    _jump.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await Bridge.ggufInspect(widget.path);
      final entries = ((r['entries'] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      final info = TokenizerInfo.fromEntries(entries);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
      if (info.tokenCount != null && info.tokenCount! > 0) {
        _loadPage(0);
        _loadSpecialTexts(info);
      }
    } catch (e) {
      widget.onLog?.call('ERROR', 'Tokenizer: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  Future<void> _loadSpecialTexts(TokenizerInfo info) async {
    final n = info.tokenCount ?? 0;
    for (final (_, id) in info.specialIds) {
      if (id < 0 || id >= n || _specialText.containsKey(id)) continue;
      try {
        final r = await Bridge.ggufArray(widget.path, _tokensKey, offset: id, limit: 1);
        final items = (r['items'] as List?) ?? const [];
        if (!mounted) return;
        if (items.isNotEmpty) setState(() => _specialText[id] = '${items.first}');
      } catch (_) {
        // Teks token khusus hanya pelengkap; kegagalan tidak mengganggu tab.
      }
    }
  }

  Future<void> _loadPage(int offset) async {
    final req = ++_req;
    setState(() {
      _pageLoading = true;
      _pageError = null;
    });
    try {
      final r = await Bridge.ggufArray(widget.path, _tokensKey, offset: offset, limit: _page);
      if (!mounted || req != _req) return;
      setState(() {
        _offset = (r['offset'] as num?)?.toInt() ?? offset;
        _items = ((r['items'] as List?) ?? const []).map((e) => '$e').toList();
        _pageLoading = false;
      });
    } catch (e) {
      if (!mounted || req != _req) return;
      setState(() {
        _pageLoading = false;
        _pageError = friendlyError(e);
      });
    }
  }

  void _go(int offset) {
    final n = _info?.tokenCount ?? 0;
    final last = n <= 0 ? 0 : ((n - 1) ~/ _page) * _page;
    _loadPage(offset.clamp(0, last));
  }

  Widget _kv(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(k, style: const TextStyle(color: muted, fontSize: 12))),
          Expanded(child: SelectableText(v, style: TextStyle(fontSize: 12, color: color))),
        ]),
      );

  String _flag(bool? v) => v == null ? 'tidak diset' : (v ? 'ya' : 'tidak');

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
    if (_error != null) return Text(_error!, style: const TextStyle(color: errorRed, fontSize: 12));
    final t = _info!;
    final issues = tokenizerIssues(t);
    final n = t.tokenCount ?? 0;
    final matches = matchTokens(_items, _offset, _filter.text);
    final end = _offset + _items.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _kv('Jenis', t.model ?? '-'),
      if (t.pre != null) _kv('Pra-tokenisasi', t.pre!),
      _kv('Jumlah token', t.tokenCount == null ? '-' : '${t.tokenCount}'),
      if (t.mergesCount != null) _kv('Merges', '${t.mergesCount}'),
      _kv('Tambah BOS', _flag(t.addBos)),
      _kv('Tambah EOS', _flag(t.addEos)),
      _kv('Template chat', t.hasChatTemplate ? 'ada' : 'tidak ada'),
      for (final (label, id) in t.specialIds)
        _kv(label, '$id${_specialText.containsKey(id) ? '  →  ${visibleToken(_specialText[id]!)}' : ''}'),
      const SizedBox(height: 8),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(border: Border.all(color: issues.isEmpty ? green : amber), borderRadius: BorderRadius.circular(8)),
        child: issues.isEmpty
            ? const Text('Pemeriksaan tokenizer: tidak ada masalah yang terdeteksi.', style: TextStyle(color: green, fontSize: 12))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Perlu diperiksa', style: TextStyle(color: amber, fontSize: 12, fontWeight: FontWeight.w600)),
                for (final i in issues) Text('• $i', style: const TextStyle(color: muted, fontSize: 11)),
              ]),
      ),
      const SizedBox(height: 4),
      const Text('Hanya baca. Ubah ID token khusus dan template chat di tab \"Metadata & template\".', style: TextStyle(color: muted, fontSize: 11)),
      if (n > 0) ...[
        const SizedBox(height: 14),
        const Text('DAFTAR TOKEN', style: TextStyle(color: muted, fontSize: 9, letterSpacing: 1.1)),
        const SizedBox(height: 6),
        TextField(
          controller: _filter,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 18), hintText: 'Cari di halaman ini (teks atau ID)', isDense: true),
        ),
        const SizedBox(height: 6),
        if (_pageError != null)
          Text(_pageError!, style: const TextStyle(color: errorRed, fontSize: 12))
        else if (_pageLoading)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
        else if (matches.isEmpty)
          const Text('Tidak ada token yang cocok di halaman ini. Pencarian hanya mencakup halaman yang sedang dibuka.', style: TextStyle(color: muted, fontSize: 11))
        else
          for (final i in matches)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('${_offset + i}  ${visibleToken(_items[i])}', style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            ),
        const SizedBox(height: 6),
        Row(children: [
          IconButton(tooltip: 'Sebelumnya', onPressed: _pageLoading || _offset == 0 ? null : () => _go(_offset - _page), icon: const Icon(Icons.chevron_left)),
          Expanded(child: Text('${_offset + 1}–$end dari $n', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12))),
          IconButton(tooltip: 'Berikutnya', onPressed: _pageLoading || end >= n ? null : () => _go(_offset + _page), icon: const Icon(Icons.chevron_right)),
        ]),
        TextField(
          controller: _jump,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'Ke indeks…', isDense: true),
          onSubmitted: (v) {
            final id = int.tryParse(v.trim());
            if (id != null) _go((id ~/ _page) * _page);
          },
        ),
      ],
    ]);
  }
}
