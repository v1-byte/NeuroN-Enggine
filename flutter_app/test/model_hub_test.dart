import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/model_hub.dart';

Map<String, dynamic> f(String name, [int size = 1]) => {'name': name, 'size': size, 'gguf': name.endsWith('.gguf')};

void main() {
  test('memilih Q4_K_M lebih dulu', () {
    final r = pickGguf([f('m-Q8_0.gguf', 9), f('m-Q4_K_M.gguf', 4), f('m-Q4_0.gguf', 3)]);
    expect(r!['name'], 'm-Q4_K_M.gguf');
  });

  test('mengabaikan shard, mmproj, dan imatrix', () {
    final r = pickGguf([
      f('m-Q4_K_M-00001-of-00002.gguf'),
      f('mmproj-m-f16.gguf'),
      f('m.imatrix.gguf'),
      f('m-Q5_K_M.gguf'),
    ]);
    expect(r!['name'], 'm-Q5_K_M.gguf');
  });

  test('fallback ke file GGUF terkecil bila kuantisasi tidak dikenal', () {
    final r = pickGguf([f('m-big.gguf', 10), f('m-small.gguf', 2)]);
    expect(r!['name'], 'm-small.gguf');
  });

  test('null bila tidak ada GGUF', () {
    expect(pickGguf([f('config.json'), f('model.safetensors')]), isNull);
  });

  test('rekomendasi model mengikuti RAM', () {
    const gb = 1024 * 1024 * 1024;
    expect(recommendModel(0).params, '1.5B');
    expect(recommendModel(1 * gb).approxBytes <= 1 * gb, true);
    expect(recommendModel(8 * gb).tag, isNot('Kuat'));
    expect(recommendModel(100).title, kModelCatalog.first.title);
  });

  test('semua repo katalog berformat owner/nama dan unik', () {
    final repos = kModelCatalog.map((m) => m.repo).toList();
    expect(repos.toSet().length, repos.length);
    for (final r in repos) {
      expect(RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(r), true, reason: r);
    }
  });
}
