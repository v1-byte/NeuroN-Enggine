import 'package:flutter/material.dart';

import 'theme.dart';

Future<void> showNeuroNTutorial(BuildContext context) async {
  final pages = <({IconData icon, String title, String body})>[
    (icon: Icons.hub_outlined, title: 'Selamat datang di NeuroN', body: 'NeuroN menjalankan AI lokal di Android atau menghubungkan ke API OpenAI-compatible. Mulai dari Beranda untuk melihat status engine.'),
    (icon: Icons.file_upload_outlined, title: 'Import model dengan rapi', body: 'Gunakan Import untuk memilih GGUF dari Download/internal storage, atau buka Hugging Face. File disalin ke ruang aplikasi dan bisa diaktifkan kembali kapan saja.'),
    (icon: Icons.chat_bubble_outline, title: 'Atur engine lalu chat', body: 'Pilih model lokal dari Model lokal, atau isi Base URL dan nama model pada Pengaturan engine. Setelah status siap, buka Chat.'),
    (icon: Icons.school_outlined, title: 'Training sederhana', body: 'Buka Training, pilih dataset, lalu pilih model dasar dari daftar NeuroN atau impor GGUF. Gunakan LoRA/QLoRA untuk memulai training remote.'),
  ];
  var index = 0;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        final page = pages[index];
        return AlertDialog(
          title: Row(children: [Icon(page.icon, color: blue), const SizedBox(width: 10), const Text('Tutorial NeuroN')]),
          content: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: SizedBox(key: ValueKey(index), width: 360, child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(page.icon, color: purple, size: 48),
              const SizedBox(height: 14),
              Text(page.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(page.body, textAlign: TextAlign.center, style: const TextStyle(color: muted, height: 1.45)),
              const SizedBox(height: 18),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (var i = 0; i < pages.length; i++) Container(width: i == index ? 20 : 7, height: 7, margin: const EdgeInsets.symmetric(horizontal: 3), decoration: BoxDecoration(color: i == index ? blue : line, borderRadius: BorderRadius.circular(5))) ]),
            ])),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Tutup')),
            if (index > 0) TextButton(onPressed: () => setState(() => index--), child: const Text('Kembali')),
            FilledButton(onPressed: () => index == pages.length - 1 ? Navigator.pop(dialogContext) : setState(() => index++), child: Text(index == pages.length - 1 ? 'Selesai' : 'Lanjut')),
          ],
        );
      },
    ),
  );
}
