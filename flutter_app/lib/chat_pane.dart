import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'flow_stepper.dart';
import 'markdown_text.dart';
import 'theme.dart';

/// Satu baris percakapan. role: 'user' | 'assistant' | 'error'.
class ChatLine {
  const ChatLine(this.role, this.text);
  final String role;
  final String text;
}

/// Panel chat: riwayat (terbaru di bawah), kolom kirim, tombol Stop saat jawaban berjalan.
/// Balasan asisten punya aksi Salin dan Perbaiki (membuka Copilot dengan jawaban itu sebagai contoh masalah).
class ChatPane extends StatelessWidget {
  const ChatPane({
    super.key,
    required this.lines,
    required this.streaming,
    required this.input,
    required this.onSend,
    required this.onStop,
    required this.hint,
    this.onFix,
    this.onEdit,
    this.onRegenerate,
    this.emptyAction,
    this.statsLabel,
    this.flowStep,
    this.suggestions = const {},
    this.notices = const [],
  });

  final List<ChatLine> lines;
  final bool streaming;
  final TextEditingController input;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final String hint;

  /// Dipanggil dengan indeks baris asisten yang ingin diperbaiki.
  final void Function(int index)? onFix;

  /// Edit pesan pengguna lalu kirim ulang dari titik itu (indeks baris pengguna).
  final void Function(int index)? onEdit;

  /// Ulangi jawaban terakhir (indeks baris asisten terakhir).
  final void Function(int index)? onRegenerate;

  /// Ringkasan kecepatan jawaban terakhir (mis. "≈12 token/dtk").
  final String? statsLabel;

  /// Langkah alur kerja yang ditampilkan di tampilan kosong (null = disembunyikan).
  final int? flowStep;

  /// Contoh perintah cepat di tampilan kosong: label chip → teks yang diisikan ke kolom pesan.
  final Map<String, String> suggestions;

  /// Peringatan non-fatal dari engine untuk permintaan terakhir (RAG dimatikan, template ChatML, riwayat dipangkas).
  final List<String> notices;

  /// Tombol ajakan di tampilan kosong (mis. "Buka Model Hub").
  final Widget? emptyAction;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: lines.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (flowStep != null) ...[FlowStepper(current: flowStep!, showHint: false), const SizedBox(height: 18)],
                    const Icon(Icons.forum_outlined, color: muted, size: 34),
                    const SizedBox(height: 12),
                    Text(hint, textAlign: TextAlign.center, style: const TextStyle(color: muted, fontSize: 12, height: 1.45)),
                    if (emptyAction != null) ...[const SizedBox(height: 16), emptyAction!],
                    if (suggestions.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                        for (final e in suggestions.entries)
                          ActionChip(
                            label: Text(e.key, style: const TextStyle(fontSize: 11)),
                            onPressed: () => input.value = TextEditingValue(
                                text: e.value, selection: TextSelection.collapsed(offset: e.value.length)),
                          ),
                      ]),
                    ],
                  ]),
                ),
              )
            : ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                itemCount: lines.length,
                itemBuilder: (_, i) {
                  final index = lines.length - 1 - i;
                  return _bubble(context, index, lines[index]);
                },
              ),
      ),
      if (notices.isNotEmpty)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(7, 0, 7, 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0x33FFB300),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orangeAccent.withOpacity(0.6)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final n in notices)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.warning_amber_rounded, size: 13, color: Colors.orangeAccent),
                  const SizedBox(width: 6),
                  Expanded(child: Text(n, style: const TextStyle(fontSize: 10.5, height: 1.35))),
                ]),
              ),
          ]),
        ),
      Padding(
        padding: const EdgeInsets.all(7),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: input,
              minLines: 1,
              maxLines: 4,
              onSubmitted: streaming ? null : (_) => onSend(),
              decoration: const InputDecoration(hintText: 'Tulis pesan…', isDense: true),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 7),
          FilledButton(
            onPressed: streaming ? onStop : onSend,
            style: FilledButton.styleFrom(
              backgroundColor: streaming ? panel2 : blue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(0, 40),
            ),
            child: Text(streaming ? 'Stop' : 'Kirim', style: const TextStyle(fontSize: 11)),
          ),
        ]),
      ),
    ]);
  }

  Widget _bubble(BuildContext context, int index, ChatLine l) {
    final mine = l.role == 'user';
    final isError = l.role == 'error';
    final isLast = index == lines.length - 1;
    final waiting = l.text.isEmpty && streaming && isLast;
    final text = l.text.isEmpty ? '…' : l.text;
    final showActions = l.role == 'assistant' && l.text.isNotEmpty && !(streaming && isLast);
    final showUserActions = mine && !streaming && onEdit != null;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF213C66) : panel2,
          borderRadius: BorderRadius.circular(11),
          border: isError ? Border.all(color: errorRed) : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (waiting)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('Memuat model / menyusun jawaban…', style: TextStyle(fontSize: 11, color: muted)),
              ]),
            )
          else if (l.role == 'assistant')
            RichMessage(text: text)
          else
            SelectableText(text, style: TextStyle(fontSize: 12, height: 1.4, color: isError ? errorRed : Colors.white)),
          if (l.role == 'assistant' && isLast && !streaming && statsLabel != null && l.text.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(statsLabel!, style: const TextStyle(fontSize: 9.5, color: muted))),
          if (showActions)
            Row(mainAxisSize: MainAxisSize.min, children: [
              _action(Icons.copy_all_outlined, 'Salin', () {
                Clipboard.setData(ClipboardData(text: l.text));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(const SnackBar(content: Text('Jawaban disalin'), duration: Duration(seconds: 1)));
              }),
              if (onRegenerate != null && isLast && !streaming) _action(Icons.refresh, 'Ulangi', () => onRegenerate!(index)),
              if (onFix != null) _action(Icons.auto_fix_high_outlined, 'Perbaiki', () => onFix!(index)),
            ]),
          if (showUserActions)
            Row(mainAxisSize: MainAxisSize.min, children: [
              _action(Icons.edit_outlined, 'Edit', () => onEdit!(index)),
            ]),
        ]),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: muted),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 10, color: muted)),
          ]),
        ),
      );
}
