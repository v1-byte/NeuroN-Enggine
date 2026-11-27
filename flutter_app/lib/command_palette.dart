import 'package:flutter/material.dart';

import 'theme.dart';

class PaletteCommand {
  const PaletteCommand(this.title, this.icon, this.run, {this.hint = '', this.enabled = true});
  final String title;
  final String hint;
  final IconData icon;
  final VoidCallback run;
  final bool enabled;
}

/// Palet perintah gaya VS Code: ketik untuk menyaring, ketuk untuk menjalankan.
/// Perintah dijalankan SETELAH dialog tertutup.
Future<void> showCommandPalette(BuildContext context, List<PaletteCommand> commands) async {
  final picked = await showDialog<PaletteCommand>(
    context: context,
    builder: (ctx) => _Palette(commands: commands),
  );
  picked?.run();
}

class _Palette extends StatefulWidget {
  const _Palette({required this.commands});
  final List<PaletteCommand> commands;

  @override
  State<_Palette> createState() => _PaletteState();
}

class _PaletteState extends State<_Palette> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = widget.commands.where((c) => q.isEmpty || c.title.toLowerCase().contains(q) || c.hint.toLowerCase().contains(q)).toList();
    return Dialog(
      backgroundColor: panel,
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(16, 60, 16, 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _q = v),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 18), hintText: 'Ketik perintah…'),
            ),
          ),
          Flexible(
            child: list.isEmpty
                ? const Padding(padding: EdgeInsets.all(16), child: Text('Tidak ada perintah yang cocok.', style: TextStyle(color: muted, fontSize: 12)))
                : ListView(shrinkWrap: true, children: [
                    for (final c in list)
                      ListTile(
                        dense: true,
                        enabled: c.enabled,
                        leading: Icon(c.icon, size: 18, color: c.enabled ? blue : muted),
                        title: Text(c.title, style: const TextStyle(fontSize: 13)),
                        subtitle: c.hint.isEmpty ? null : Text(c.hint, style: const TextStyle(color: muted, fontSize: 10)),
                        onTap: c.enabled ? () => Navigator.pop(context, c) : null,
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }
}
