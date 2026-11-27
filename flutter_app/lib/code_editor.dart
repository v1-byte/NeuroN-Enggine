import 'package:flutter/material.dart';

import 'editor_assist.dart';
import 'syntax_highlight.dart';
import 'theme.dart';

const _lineStyle = TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.65);
const _batasLipat = 200000; // di atas ini lipat blok dimatikan agar editor tetap ringan

/// Editor kode: nomor baris di kiri, teks di kanan. Keduanya digulir bersama dalam satu scroll.
///
/// Dua alat tambahan:
/// - Lipat blok (JSON): ketuk nomor baris yang bertanda ▾ untuk melipat `{}`/`[]` multi-baris.
///   Selama ada blok terlipat, teks tampil hanya-baca; buka semua lipatan untuk mengedit lagi.
///   Teks asli tidak pernah diubah oleh lipatan.
/// - Autocomplete: usulan kata di atas keyboard, dari kosakata berkas dan kata yang sudah ada.
class CodeEditor extends StatefulWidget {
  const CodeEditor({
    super.key,
    required this.controller,
    required this.onChanged,
    this.language = SyntaxLanguage.none,
    this.path,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final SyntaxLanguage language;
  final String? path;

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  Set<int> _folded = {};

  void _toggle(int start) => setState(() {
        _folded = {..._folded};
        if (!_folded.remove(start)) _folded.add(start);
      });

  void _accept(TextEditingValue v, String word) {
    final c = applySuggestion(v.text, v.selection.baseOffset, word);
    widget.controller.value = TextEditingValue(text: c.text, selection: TextSelection.collapsed(offset: c.cursor));
    widget.onChanged(c.text);
  }

  Widget _gutterRow(int number, {required bool foldable, required bool folded, VoidCallback? onTap}) {
    final row = Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 12,
        child: foldable ? Text(folded ? '▸' : '▾', style: _lineStyle.copyWith(color: blue, fontSize: 10)) : null,
      ),
      Text('$number', style: _lineStyle.copyWith(color: const Color(0xFF68718A))),
    ]);
    return onTap == null ? row : GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: row);
  }

  Widget _body(TextEditingValue value) {
    final text = value.text;
    final canFold = text.length <= _batasLipat;
    final regions = canFold ? foldRegions(text, widget.language) : const <FoldRegion>[];
    final starts = {for (final r in regions) r.startLine};
    final folded = pruneFolds(_folded, regions);
    const gutterPad = EdgeInsets.only(left: 4, right: 8);
    const textStyle = TextStyle(color: Color(0xFFDCE4FF), fontFamily: 'monospace', fontSize: 12, height: 1.65);

    if (folded.isNotEmpty) {
      final lines = applyFolds(text, folded, regions);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          color: const Color(0xFF1B2540),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(children: [
            const Expanded(child: Text('Ada blok terlipat: tampilan hanya-baca.', style: TextStyle(color: muted, fontSize: 11))),
            TextButton(onPressed: () => setState(() => _folded = {}), child: const Text('Buka semua', style: TextStyle(fontSize: 11))),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 10, bottom: 24),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: gutterPad,
                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  for (final l in lines)
                    _gutterRow(l.number,
                        foldable: starts.contains(l.number - 1),
                        folded: l.foldStart != null,
                        onTap: starts.contains(l.number - 1) ? () => _toggle(l.number - 1) : null),
                ]),
              ),
              Expanded(child: SelectableText(lines.map((l) => l.text).join('\n'), style: textStyle)),
            ]),
          ),
        ),
      ]);
    }

    final count = text.split('\n').length;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 10, bottom: 24),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: gutterPad,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 1; i <= count; i++)
              _gutterRow(i,
                  foldable: starts.contains(i - 1),
                  folded: false,
                  onTap: starts.contains(i - 1) ? () => _toggle(i - 1) : null),
          ]),
        ),
        Expanded(
          child: TextField(
            controller: widget.controller,
            onChanged: widget.onChanged,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            style: textStyle,
            decoration: const InputDecoration(border: InputBorder.none, filled: false, isCollapsed: true),
          ),
        ),
      ]),
    );
  }

  Widget _suggestions(TextEditingValue v) {
    final sel = v.selection;
    final composing = v.composing.isValid && !v.composing.isCollapsed;
    if (_folded.isNotEmpty || !sel.isValid || !sel.isCollapsed || composing || v.text.length > _batasLipat) {
      return const SizedBox.shrink();
    }
    final words = suggest(v.text, sel.baseOffset, widget.language, path: widget.path);
    if (words.isEmpty) return const SizedBox.shrink();
    return Container(
      height: 36,
      width: double.infinity,
      color: const Color(0xFF1B2540),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        children: [
          for (final w in words)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text(w, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                onPressed: () => _accept(v, w),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF111522),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: widget.controller,
        builder: (context, value, _) => Column(children: [
          Expanded(child: _body(value)),
          _suggestions(value),
        ]),
      ),
    );
  }
}
