import 'package:flutter/material.dart';

import 'theme.dart';

/// Langkah alur kerja lokal: pilih model → unduh → jalankan → chat & edit.
const kFlowSteps = ['Pilih model', 'Unduh', 'Jalankan', 'Chat & edit'];

/// Petunjuk singkat untuk langkah yang sedang aktif.
const kFlowHints = [
  'Langkah 1: pilih satu model GGUF dari katalog, sesuaikan dengan RAM perangkat.',
  'Langkah 2: model sedang diunduh. Proses berjalan di latar belakang dan bisa dilanjutkan.',
  'Langkah 3: tekan Jalankan untuk memuat model ke memori.',
  'Langkah 4: model siap. Buka Chat, minta Copilot memperbaiki jawaban, atau edit konfigurasi.',
];

/// Menentukan langkah aktif (0..3) dari status model. Fungsi murni agar mudah diuji.
int flowStepFor({required bool downloading, required bool hasModel, required bool loaded}) {
  if (downloading) return 1;
  if (!hasModel) return 0;
  return loaded ? 3 : 2;
}

/// Indikator alur 4 langkah. Langkah selesai berwarna hijau, langkah aktif memakai warna aksen.
class FlowStepper extends StatelessWidget {
  const FlowStepper({super.key, required this.current, this.showHint = true});

  final int current;
  final bool showHint;

  @override
  Widget build(BuildContext context) {
    final step = current.clamp(0, kFlowSteps.length - 1);
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      label: 'Alur kerja: langkah ${step + 1} dari ${kFlowSteps.length}, ${kFlowSteps[step]}',
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < kFlowSteps.length; i++) ...[
              _node(i, step, accent),
              if (i < kFlowSteps.length - 1)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Container(height: 2, color: i < step ? green : line),
                  ),
                ),
            ],
          ]),
          if (showHint) ...[
            const SizedBox(height: 10),
            Text(kFlowHints[step], style: const TextStyle(fontSize: 11, color: muted, height: 1.4)),
          ],
        ]),
      ),
    );
  }

  Widget _node(int i, int step, Color accent) {
    final done = i < step;
    final active = i == step;
    final color = done ? green : (active ? accent : muted);
    return SizedBox(
      width: 62,
      child: Column(children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? green : (active ? accent : Colors.transparent),
            border: Border.all(color: color, width: 1.5),
          ),
          child: done
              ? const Icon(Icons.check, size: 14, color: Colors.black)
              : Text('${i + 1}',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: active ? Colors.white : muted)),
        ),
        const SizedBox(height: 5),
        Text(kFlowSteps[i],
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(fontSize: 9.5, height: 1.2, fontWeight: active ? FontWeight.w700 : FontWeight.w500, color: color)),
      ]),
    );
  }
}
