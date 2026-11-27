import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_info.dart';
import 'bridge.dart';
import 'model_hub.dart';
import 'theme.dart';

const kOnboardedKey = 'neuron.onboarded.v1';

/// Wizard pertama kali: sambutan → cek perangkat dan rekomendasi model → mulai.
/// Hasil: 'download:<repo>' untuk mengunduh model rekomendasi, 'skip' untuk melewati.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});
  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  int _step = 0;
  Map<String, dynamic> _health = const {};
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final h = await Bridge.deviceHealth();
      if (mounted) setState(() => _health = h);
    } catch (_) {}
    if (mounted) setState(() => _checked = true);
  }

  int get _max => (_health['recommendedMaxModel'] as num?)?.toInt() ?? 0;

  Future<void> _finish(String result) async {
    try {
      (await SharedPreferences.getInstance()).setBool(kOnboardedKey, true);
    } catch (_) {}
    if (mounted) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish('skip');
      },
      child: Scaffold(
        backgroundColor: ink,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                for (var i = 0; i < 3; i++)
                  Expanded(
                    child: Container(
                      height: 4,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(color: i <= _step ? blue : line, borderRadius: BorderRadius.circular(4)),
                    ),
                  ),
                TextButton(onPressed: () => _finish('skip'), child: const Text('Lewati')),
              ]),
              Expanded(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.only(top: 24), child: [_welcome, _device, _ready][_step]()))),
              Row(children: [
                if (_step > 0) TextButton(onPressed: () => setState(() => _step--), child: const Text('Kembali')),
                const Spacer(),
                if (_step < 2) FilledButton(onPressed: () => setState(() => _step++), style: FilledButton.styleFrom(backgroundColor: blue, minimumSize: const Size(110, 44)), child: const Text('Lanjut')),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _welcome() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.asset('assets/images/neuron_mark.png', width: 64, height: 64, errorBuilder: (_, __, ___) => const Icon(Icons.memory, size: 64, color: blue)),
        ),
        const SizedBox(height: 18),
        const Text('Selamat datang di $kAppName', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        const Text('Jalankan model AI langsung di HP Anda. Tanpa akun, tanpa server.', style: TextStyle(fontSize: 14, color: muted, height: 1.5)),
        const SizedBox(height: 22),
        _point(Icons.lock_outline, 'Privat', 'Percakapan dan model tersimpan di perangkat ini.'),
        _point(Icons.download_outlined, 'Model GGUF', 'Unduh dari katalog sekali tap, atau impor file sendiri.'),
        _point(Icons.auto_fix_high_outlined, 'Bisa diperbaiki', 'Copilot membantu menyetel prompt dan parameter dari hasil chat.'),
      ]);

  Widget _point(IconData icon, String title, String detail) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: blue, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(detail, style: const TextStyle(fontSize: 12, color: muted, height: 1.4)),
          ])),
        ]),
      );

  Widget _device() {
    final ram = _health['totalRam'] as num?;
    final free = _health['freeStorage'] as num?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Cek perangkat', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      const Text('Kami menyesuaikan rekomendasi model dengan kemampuan HP Anda.', style: TextStyle(fontSize: 13, color: muted, height: 1.5)),
      const SizedBox(height: 20),
      Card(
        color: panel,
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: !_checked
              ? const Row(children: [SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 12), Text('Memeriksa…')])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(ram == null ? 'Info perangkat tidak tersedia; kami pilih model aman.' : 'RAM ${_fmt(ram)} · Penyimpanan bebas ${_fmt(free)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  if (ram != null && (_health['warnings'] as List?)?.isNotEmpty == true) ...[
                    const SizedBox(height: 8),
                    for (final w in (_health['warnings'] as List)) Text('• $w', style: const TextStyle(fontSize: 11, color: amber, height: 1.4)),
                  ],
                ]),
        ),
      ),
    ]);
  }

  String _fmt(num? v) {
    final n = (v ?? 0).toDouble();
    if (n <= 0) return '—';
    return n >= 1024 * 1024 * 1024 ? '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB' : '${(n / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  Widget _ready() {
    final m = recommendModel(_max);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Model untuk Anda', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      Card(
        color: panel,
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('${m.params} parameter · sekitar ${(m.approxBytes / (1024 * 1024)).round()} MB', style: const TextStyle(fontSize: 11, color: muted)),
            const SizedBox(height: 8),
            Text(m.note, style: const TextStyle(fontSize: 12, height: 1.4)),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      const Text('Unduhan memakai kuota data dan berjalan di latar belakang. Disarankan Wi-Fi.', style: TextStyle(fontSize: 11, color: muted, height: 1.4)),
      const SizedBox(height: 22),
      FilledButton.icon(
        onPressed: () => _finish('download:${m.repo}'),
        icon: const Icon(Icons.download),
        label: const Text('Unduh dan mulai'),
        style: FilledButton.styleFrom(backgroundColor: blue, minimumSize: const Size.fromHeight(48)),
      ),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: () => _finish('skip'), style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)), child: const Text('Nanti saja')),
    ]);
  }
}
