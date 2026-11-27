import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/model_profile_fill.dart';

Map<String, dynamic> _json(String? text) => jsonDecode(text!) as Map<String, dynamic>;

const _profile = <String, dynamic>{
  'path': '/data/models/qwen.gguf',
  'name': 'qwen.gguf',
  'architecture': 'qwen2',
  'fileType': 15,
  'contextLength': 2048,
  'embeddingLength': 896,
  'blockCount': 24,
  'feedForwardLength': 4864,
  'headCount': 14,
  'headCountKv': 2,
  'vocabSize': 151936,
  'chatTemplate': '{% for m in messages %}{{ m.content }}{% endfor %}',
};

void main() {
  test('hanya empat berkas yang bisa diisi dari model', () {
    expect(canFillFromModel('model/config.json'), isTrue);
    expect(canFillFromModel('model/chat_template.jinja'), isTrue);
    expect(canFillFromModel('model/quantization.json'), isTrue);
    expect(canFillFromModel('chat/params.json'), isTrue);
    expect(canFillFromModel('tokenizer/vocab.json'), isFalse);
    expect(canFillFromModel(null), isFalse);
  });

  group('chat_template.jinja', () {
    test('diisi dari header', () {
      final r = fillFromProfile('model/chat_template.jinja', '', _profile);
      expect(r.text, _profile['chatTemplate']);
    });
    test('model tanpa template tidak mengubah apa pun', () {
      final r = fillFromProfile('model/chat_template.jinja', 'lama', {..._profile, 'chatTemplate': null});
      expect(r.text, isNull);
      expect(r.message, contains('tidak punya'));
    });
    test('template yang sama tidak dianggap perubahan', () {
      final r = fillFromProfile('model/chat_template.jinja', _profile['chatTemplate'] as String, _profile);
      expect(r.text, isNull);
    });
  });

  group('config.json', () {
    test('menggabung field model dan mempertahankan field lain', () {
      final r = fillFromProfile('model/config.json', '{"catatan": "punya saya", "hidden_size": 1}', _profile);
      final out = _json(r.text);
      expect(out['catatan'], 'punya saya');
      expect(out['hidden_size'], 896);
      expect(out['model_type'], 'qwen2');
      expect(out['max_position_embeddings'], 2048);
      expect(out['num_hidden_layers'], 24);
      expect(out['num_key_value_heads'], 2);
      expect(out['vocab_size'], 151936);
    });
    test('berkas kosong dianggap objek kosong', () {
      expect(_json(fillFromProfile('model/config.json', '', _profile).text)['model_type'], 'qwen2');
    });
    test('field yang tidak ada di header tidak ditulis', () {
      final r = fillFromProfile('model/config.json', '{}', {'name': 'x.gguf', 'architecture': 'llama', 'headCountKv': null});
      final out = _json(r.text);
      expect(out.keys, ['model_type']);
    });
    test('header tanpa dimensi tidak mengubah berkas', () {
      final r = fillFromProfile('model/config.json', '{}', {'name': 'x.gguf'});
      expect(r.text, isNull);
    });
    test('JSON rusak ditolak, bukan ditimpa', () {
      final r = fillFromProfile('model/config.json', '{rusak', _profile);
      expect(r.text, isNull);
      expect(r.message, contains('bukan JSON'));
    });
    test('hasil yang sudah sama tidak dianggap perubahan', () {
      final first = fillFromProfile('model/config.json', '{}', _profile).text!;
      expect(fillFromProfile('model/config.json', first, _profile).text, isNull);
    });
  });

  group('quantization.json', () {
    test('mengisi path dan nama kuantisasi', () {
      final r = fillFromProfile('model/quantization.json', '{"modelPath": "", "format": "GGUF", "quantization": "F16"}', _profile);
      final out = _json(r.text);
      expect(out['modelPath'], '/data/models/qwen.gguf');
      expect(out['quantization'], 'Q4_K_M');
      expect(out['format'], 'GGUF');
    });
    test('tipe file yang tidak dikenal tidak menimpa kuantisasi', () {
      final r = fillFromProfile('model/quantization.json', '{"quantization": "Q8_0"}', {..._profile, 'fileType': 99});
      expect(_json(r.text)['quantization'], 'Q8_0');
    });
  });

  group('chat/params.json', () {
    test('menurunkan contextLength yang melebihi batas model', () {
      final r = fillFromProfile('chat/params.json', '{"temperature": 0.5, "contextLength": 4096}', _profile);
      final out = _json(r.text);
      expect(out['contextLength'], 2048);
      expect(out['temperature'], 0.5);
    });
    test('contextLength yang sudah di bawah batas tidak dinaikkan', () {
      final r = fillFromProfile('chat/params.json', '{"contextLength": 1024}', _profile);
      expect(r.text, isNull);
      expect(r.message, contains('sudah dalam batas'));
    });
    test('model tanpa panjang konteks tidak mengubah apa pun', () {
      expect(fillFromProfile('chat/params.json', '{"contextLength": 4096}', {..._profile, 'contextLength': null}).text, isNull);
    });
  });

  test('berkas lain ditolak dengan pesan', () {
    final r = fillFromProfile('tokenizer/vocab.json', '{}', _profile);
    expect(r.text, isNull);
    expect(r.message, contains('tidak bisa diisi'));
  });
}
