import 'package:flutter/material.dart';

import 'theme.dart';

// Sinkronkan dengan `version:` di pubspec.yaml dan CHANGELOG.md.
const kAppName = 'NeuroN Engine';
const kAppVersion = '0.3.10';
const kAppBuild = '21';

// Identitas "dibuat oleh". Ubah atau kosongkan di sini bila tidak diperlukan.
const kMakerName = 'Frostbyte Technologies';
const kMakerSite = 'frostbyte.tech';
const kMakerTagline = 'Innovate • Build • Connect';
const kMakerContact = '082328597909 / +66975842024';

Future<void> showAboutNeuroN(BuildContext context) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        title: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/images/neuron_mark.png', width: 40, height: 40, errorBuilder: (_, __, ___) => const Icon(Icons.memory, size: 40, color: blue)),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(kAppName, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            Text('Versi $kAppVersion ($kAppBuild)', style: TextStyle(fontSize: 11, color: muted)),
          ])),
        ]),
        content: const Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Engine AI lokal untuk Android: model GGUF, chat, RAG, dan Copilot, semuanya di perangkat Anda.',
              style: TextStyle(fontSize: 12, height: 1.45)),
          SizedBox(height: 14),
          Text('Dibuat oleh $kMakerName', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          SizedBox(height: 2),
          Text(kMakerTagline, style: TextStyle(fontSize: 11, color: muted)),
          SizedBox(height: 6),
          SelectableText('$kMakerSite\nKontak: $kMakerContact', style: TextStyle(fontSize: 11, color: muted, height: 1.5)),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup'))],
      ),
    );
