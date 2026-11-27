import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/tokenizer_logic.dart';

Map<String, dynamic> e(String key, Object? value, {int? count}) => {'key': key, 'value': value, 'count': count};

void main() {
  List<Map<String, dynamic>> base() => [
        e('tokenizer.ggml.model', 'gpt2'),
        e('tokenizer.ggml.tokens', '[…]', count: 1000),
        e('tokenizer.ggml.merges', '[…]', count: 500),
        e('tokenizer.ggml.token_type', '[…]', count: 1000),
        e('tokenizer.ggml.bos_token_id', '1'),
        e('tokenizer.ggml.eos_token_id', '2'),
        e('tokenizer.ggml.add_bos_token', 'false'),
        e('tokenizer.chat_template', '{{ x }}'),
      ];

  test('membaca key tokenizer dari entri ggufInspect', () {
    final t = TokenizerInfo.fromEntries(base());
    expect(t.model, 'gpt2');
    expect(t.tokenCount, 1000);
    expect(t.mergesCount, 500);
    expect(t.bos, 1);
    expect(t.eos, 2);
    expect(t.addBos, false);
    expect(t.hasChatTemplate, true);
    expect(t.specialIds, [('BOS', 1), ('EOS', 2)]);
    expect(tokenizerIssues(t), isEmpty);
  });

  test('ID di luar daftar token dan EOS hilang dilaporkan', () {
    final entries = base()
      ..removeWhere((x) => x['key'] == 'tokenizer.ggml.eos_token_id')
      ..removeWhere((x) => x['key'] == 'tokenizer.ggml.bos_token_id')
      ..add(e('tokenizer.ggml.bos_token_id', '5000'));
    final issues = tokenizerIssues(TokenizerInfo.fromEntries(entries));
    expect(issues.any((s) => s.contains('BOS (5000)')), true);
    expect(issues.any((s) => s.contains('EOS tidak diset')), true);
  });

  test('tanpa daftar token: satu temuan saja', () {
    final t = TokenizerInfo.fromEntries([e('general.name', 'x')]);
    expect(tokenizerIssues(t).length, 1);
  });

  test('BPE tanpa merges dilaporkan', () {
    final entries = base()..removeWhere((x) => x['key'] == 'tokenizer.ggml.merges');
    expect(tokenizerIssues(TokenizerInfo.fromEntries(entries)).any((s) => s.contains('merges')), true);
  });

  test('visibleToken membuat karakter kontrol terlihat', () {
    expect(visibleToken(''), '(kosong)');
    expect(visibleToken('a\nb'), r'a\nb');
    expect(visibleToken('\u2581the'), '·the');
    expect(visibleToken('\u0001'), r'\x01');
  });

  test('matchTokens mencocokkan teks dan ID', () {
    final items = ['hello', 'World', '\u2581the', 'x'];
    expect(matchTokens(items, 10, 'wor'), [1]);
    expect(matchTokens(items, 10, '12'), [2]);
    expect(matchTokens(items, 10, ''), [0, 1, 2, 3]);
  });
}
