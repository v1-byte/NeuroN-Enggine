import 'dart:convert';

/// Daftar tab berkas yang terbuka dan tab aktifnya, untuk dipulihkan saat aplikasi dibuka lagi.
class TabSession {
  const TabSession(this.open, this.active);
  final List<String> open;
  final String? active;
}

/// Berkas yang tidak ikut dipulihkan. engine/api.json bisa berisi kunci API, jadi tidak
/// dibuka otomatis saat aplikasi mulai.
const _tidakDipulihkan = {'engine/api.json'};

const kTabSessionKey = 'neuron.open_tabs.v1';

String encodeTabSession(List<String> open, String? active) => jsonEncode({
      'open': [
        for (final p in open)
          if (!_tidakDipulihkan.contains(p)) p,
      ],
      'active': active != null && !_tidakDipulihkan.contains(active) ? active : null,
    });

/// Baca sesi tersimpan. Aman terhadap data rusak: hasilnya kosong, tidak melempar.
/// Hanya path yang masih ada di [validPaths] yang dipertahankan, tanpa duplikat, urutan tetap.
TabSession decodeTabSession(String? raw, List<String> validPaths) {
  if (raw == null || raw.isEmpty) return const TabSession([], null);
  try {
    final j = jsonDecode(raw);
    if (j is! Map) return const TabSession([], null);
    final valid = validPaths.toSet();
    final seen = <String>{};
    final open = <String>[
      for (final p in (j['open'] is List ? j['open'] as List : const []))
        if (p is String && valid.contains(p) && !_tidakDipulihkan.contains(p) && seen.add(p)) p,
    ];
    final a = j['active'];
    final active = a is String && open.contains(a) ? a : (open.isEmpty ? null : open.last);
    return TabSession(open, active);
  } catch (_) {
    return const TabSession([], null);
  }
}
