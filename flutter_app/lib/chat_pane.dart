import 'package:flutter/material.dart';

import 'theme.dart';

/// Satu baris percakapan. role: 'user' | 'assistant' | 'error'.
class ChatLine {
  const ChatLine(this.role, this.text);
  final String role;
  final String text;
}

/// Panel chat: riwayat (terbaru di bawah), kolom kirim, tombol Stop saat jawaban berjalan.
class ChatPane extends StatelessWidget {
  const ChatPane({
    super.key,
    required this.lines,
    required this.streaming,
    required this.input,
    required this.onSend,
    required this.onStop,
    required this.hint,
  });

  final List<ChatLine> lines;
  final bool streaming;
  final TextEditingController input;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: lines.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(hint, textAlign: TextAlign.center, style: const TextStyle(color: muted, fontSize: 11)),
                ),
              )
            : ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                itemCount: lines.length,
                itemBuilder: (_, i) => _bubble(lines[lines.length - 1 - i]),
              ),
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

  Widget _bubble(ChatLine l) {
    final mine = l.role == 'user';
    final isError = l.role == 'error';
    final text = l.text.isEmpty ? '…' : l.text;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF213C66) : panel2,
          borderRadius: BorderRadius.circular(11),
          border: isError ? Border.all(color: errorRed) : null,
        ),
        child: SelectableText(
          text,
          style: TextStyle(fontSize: 12, color: isError ? errorRed : Colors.white),
        ),
      ),
    );
  }
}
