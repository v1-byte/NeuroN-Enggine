import 'package:flutter/services.dart';

/// Ubah pesan error teknis menjadi kalimat yang bisa ditindaklanjuti pengguna.
/// Pesan asli tetap dicatat di log oleh pemanggil; fungsi ini hanya untuk tampilan.
String friendlyError(Object error) {
  // Kegagalan engine membawa kode jenisnya dari Kotlin (EngineErrorKind): tampilkan sebagai kategori yang berbeda
  // alih-alih menebak dari teks. Pesan detail (apa yang salah dan apa yang bisa dilakukan) datang dari engine.
  if (error is PlatformException) {
    final detail = (error.message ?? '').trim();
    final label = switch (error.code) {
      'ENGINE_NATIVE' => 'Mesin native (llama.cpp) tidak siap',
      'ENGINE_MODEL' => 'Model tidak bisa dipakai',
      'ENGINE_RAM' => 'RAM tidak cukup',
      'ENGINE_CONTEXT' => 'Konteks terlampaui',
      'ENGINE_CANCELLED' => 'Generate dibatalkan',
      _ => null,
    };
    if (label != null) return detail.isEmpty ? label : '$label: $detail';
  }
  final raw = error is PlatformException ? (error.message ?? error.code) : '$error';
  final l = raw.toLowerCase();
  if (l.contains('unknownhost') ||
      l.contains('unable to resolve host') ||
      l.contains('failed host lookup') ||
      l.contains('network is unreachable') ||
      l.contains('socketexception')) {
    return 'Tidak ada koneksi internet. Periksa jaringan lalu coba lagi.';
  }
  if (l.contains('timeout') || l.contains('timed out')) {
    return 'Koneksi terlalu lama merespons. Coba lagi beberapa saat lagi.';
  }
  if (l.contains('enospc') || l.contains('no space left') || l.contains('ruang penyimpanan tidak cukup')) {
    return 'Ruang penyimpanan tidak cukup. Hapus model atau file yang tidak dipakai, lalu coba lagi.';
  }
  if (l.contains('outofmemory') || l.contains('out of memory')) {
    return 'Memori perangkat tidak cukup untuk model ini. Pilih model yang lebih kecil atau kecilkan panjang konteks di Pengaturan model.';
  }
  if (l.contains('library native') || l.contains('unsatisfiedlink')) {
    return 'Mesin lokal (llama.cpp) belum ada di aplikasi ini. Gunakan build dengan -PwithNative.';
  }
  if (l.contains('file model tidak ditemukan')) {
    return 'File model tidak ditemukan. Pilih atau unduh model lagi di Model Hub.';
  }
  if (RegExp(r'\b(401|403)\b').hasMatch(l) || l.contains('unauthorized') || l.contains('forbidden')) {
    return 'Akses ditolak. Periksa API key atau token Hugging Face (model tertentu memerlukan persetujuan akses).';
  }
  if (RegExp(r'\b404\b').hasMatch(l)) {
    return 'Sumber tidak ditemukan (404). Repository atau file mungkin sudah dipindah atau dihapus.';
  }
  if (RegExp(r'\b429\b').hasMatch(l)) {
    return 'Terlalu banyak permintaan. Tunggu sebentar lalu coba lagi.';
  }
  return raw;
}
