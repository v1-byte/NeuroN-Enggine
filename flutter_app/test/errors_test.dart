import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/errors.dart';

void main() {
  test('jaringan', () {
    expect(friendlyError('java.net.UnknownHostException: huggingface.co'), contains('koneksi internet'));
  });
  test('penyimpanan, memori, native', () {
    expect(friendlyError('write failed: ENOSPC'), contains('penyimpanan'));
    expect(friendlyError('java.lang.OutOfMemoryError'), contains('Memori'));
    expect(friendlyError('Library native belum ada'), contains('llama.cpp'));
  });
  test('akses dan 404, tanpa salah cocok pada kata lain', () {
    expect(friendlyError('HTTP 401'), contains('Akses ditolak'));
    expect(friendlyError('HTTP 404'), contains('tidak ditemukan'));
    expect(friendlyError('ruang kamar 4040'), 'ruang kamar 4040');
  });
  test('PlatformException memakai message; pesan tak dikenal dikembalikan apa adanya', () {
    expect(friendlyError(PlatformException(code: 'X', message: 'timed out')), contains('lama'));
    expect(friendlyError('kesalahan aneh'), 'kesalahan aneh');
  });
  test('kode ENGINE_* dibedakan per jenis dan membawa detail dari engine', () {
    String f(String code, [String msg = 'detail']) => friendlyError(PlatformException(code: code, message: msg));
    expect(f('ENGINE_NATIVE'), allOf(contains('native'), contains('detail')));
    expect(f('ENGINE_MODEL'), contains('Model'));
    expect(f('ENGINE_RAM'), contains('RAM'));
    expect(f('ENGINE_CONTEXT'), contains('Konteks'));
    expect(f('ENGINE_CANCELLED'), contains('dibatalkan'));
    final all = {for (final c in ['ENGINE_NATIVE', 'ENGINE_MODEL', 'ENGINE_RAM', 'ENGINE_CONTEXT', 'ENGINE_CANCELLED']) f(c, '')};
    expect(all.length, 5);
  });
  test('kode tak dikenal tetap memakai pesan apa adanya', () {
    expect(friendlyError(PlatformException(code: 'CHAT_ERROR', message: 'kesalahan aneh')), 'kesalahan aneh');
  });
}
