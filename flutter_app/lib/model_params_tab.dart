import 'package:flutter/material.dart';

import 'bridge.dart';
import 'errors.dart';
import 'model_params_logic.dart';
import 'theme.dart';

/// Tab Parameter: nilai generate khusus untuk satu model (menimpa nilai proyek untuk model itu saja),
/// plus uji cepat pada model aktif. Kolom kosong = ikut proyek.
class ModelParamsPanel extends StatefulWidget {
  const ModelParamsPanel({super.key, required this.path, required this.isActive, this.onLog});

  final String path;
  final bool isActive;
  final void Function(String level, String message)? onLog;

  @override
  State<ModelParamsPanel> createState() => _ModelParamsPanelState();
}

class _ModelParamsPanelState extends State<ModelParamsPanel> {
  final Map<String, TextEditingController> _c = {for (final f in paramFields) f.key: TextEditingController()};
  final _prompt = TextEditingController(text: 'Jelaskan apa itu fotosintesis dalam dua kalimat.');
  Map<String, dynamic> _state = const {};
  bool _loading = true;
  bool _busy = false;
  String _status = '';
  bool _statusIsError = false;
  bool _testing = false;
  Map<String, dynamic>? _result;
  String _testError = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _prompt.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _overrides => Map<String, dynamic>.from((_state['overrides'] as Map?) ?? const {});
  Map<String, dynamic> get _base => Map<String, dynamic>.from((_state['base'] as Map?) ?? const {});

  void _fill(Map<String, dynamic> state) {
    _state = state;
    final texts = formTexts(_overrides);
    for (final f in paramFields) {
      _c[f.key]!.text = texts[f.key] ?? '';
    }
  }

  Future<void> _load() async {
    try {
      final s = await Bridge.modelParamsGet(widget.path);
      if (!mounted) return;
      setState(() {
        _fill(s);
        _loading = false;
      });
    } catch (e) {
      widget.onLog?.call('ERROR', 'Parameter model: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _status = friendlyError(e);
          _statusIsError = true;
        });
      }
    }
  }

  ParamsForm get _form => readParamsForm({for (final e in _c.entries) e.key: e.value.text});

  Future<void> _save() async {
    final form = _form;
    if (!form.ok || _busy) return;
    final reload = contextWillChange(_overrides, form.values);
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      final s = await Bridge.modelParamsSave(widget.path, form.json);
      if (!mounted) return;
      setState(() {
        _fill(s);
        _statusIsError = false;
        _status = form.values.isEmpty
            ? 'Tidak ada penimpas: model ini mengikuti nilai proyek.'
            : 'Tersimpan.${reload ? ' Panjang konteks berubah, jadi model dimuat ulang pada permintaan berikutnya.' : ''}';
      });
      widget.onLog?.call('INFO', 'Parameter model disimpan: ${_state['name']}');
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusIsError = true;
          _status = friendlyError(e);
        });
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _reset() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '';
    });
    try {
      final reload = _overrides.containsKey('contextLength');
      final s = await Bridge.modelParamsClear(widget.path);
      if (!mounted) return;
      setState(() {
        _fill(s);
        _statusIsError = false;
        _status = 'Dikembalikan ke nilai proyek.${reload ? ' Model dimuat ulang pada permintaan berikutnya.' : ''}';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusIsError = true;
          _status = friendlyError(e);
        });
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _test() async {
    final form = _form;
    if (!form.ok || _testing) return;
    setState(() {
      _testing = true;
      _result = null;
      _testError = '';
    });
    try {
      final r = await Bridge.modelParamsTest(widget.path, _prompt.text, form.json);
      if (mounted) setState(() => _result = r);
    } catch (e) {
      widget.onLog?.call('ERROR', 'Uji parameter: $e');
      if (mounted) setState(() => _testError = friendlyError(e));
    }
    if (mounted) setState(() => _testing = false);
  }

  String _baseText(ParamField f) {
    final v = _base[f.key];
    return v is num ? shownNumber(v, integer: f.integer) : '-';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()));
    final form = _form;
    final r = _result;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text(
        'Nilai di sini hanya berlaku untuk model ini dan menimpa nilai proyek (chat/params.json, Modelfile). Kosongkan kolom untuk ikut proyek.',
        style: TextStyle(color: muted, fontSize: 12, height: 1.4),
      ),
      const SizedBox(height: 10),
      for (final f in paramFields)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: _c[f.key],
            onChanged: (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: InputDecoration(
              labelText: f.label,
              hintText: 'proyek: ${_baseText(f)}',
              helperText: f.hint,
              helperMaxLines: 2,
              errorText: form.errors[f.key],
              isDense: true,
            ),
          ),
        ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton(onPressed: form.ok && !_busy ? _save : null, child: const Text('Simpan')),
        OutlinedButton(onPressed: _busy || _overrides.isEmpty ? null : _reset, child: const Text('Kembalikan ke proyek')),
      ]),
      if (_status.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_status, style: TextStyle(color: _statusIsError ? errorRed : green, fontSize: 12)),
        ),
      const SizedBox(height: 16),
      const Text('UJI CEPAT', style: TextStyle(color: muted, fontSize: 9, letterSpacing: 1.1)),
      const SizedBox(height: 4),
      const Text(
        'Memakai nilai di form (belum perlu disimpan) pada model aktif, tanpa tools dan guardrail. Panjang konteks baru berlaku setelah disimpan.',
        style: TextStyle(color: muted, fontSize: 11, height: 1.4),
      ),
      if (!widget.isActive)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Model ini belum aktif. Aktifkan di tab Kelola untuk menjalankan uji.', style: TextStyle(color: amber, fontSize: 11)),
        ),
      const SizedBox(height: 8),
      TextField(
        controller: _prompt,
        minLines: 2,
        maxLines: 5,
        maxLength: 4000,
        decoration: const InputDecoration(labelText: 'Prompt uji', isDense: true),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonal(
          onPressed: widget.isActive && form.ok && !_testing ? _test : null,
          child: Text(_testing ? 'Menjalankan…' : 'Jalankan uji'),
        ),
      ),
      if (_testing) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
      if (_testError.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(_testError, style: const TextStyle(color: errorRed, fontSize: 12))),
      if (r != null) ...[
        const SizedBox(height: 10),
        Text(
          '${r['tokens'] ?? 0} token · ${r['ms'] ?? 0} ms · ${r['tps'] ?? 0} token/detik',
          style: const TextStyle(color: muted, fontSize: 11),
        ),
        if (r['contextPinned'] == true)
          const Text('Panjang konteks di form belum dipakai pada uji ini; simpan dulu agar model dimuat ulang.', style: TextStyle(color: amber, fontSize: 11)),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(border: Border.all(color: line), borderRadius: BorderRadius.circular(8)),
          child: SelectableText('${r['text'] ?? ''}'.isEmpty ? '(tidak ada keluaran)' : '${r['text']}', style: const TextStyle(fontSize: 12)),
        ),
      ],
    ]);
  }
}
