import 'package:flutter_test/flutter_test.dart';
import 'package:neuron_engine/conversation_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('judul dari pesan pengguna pertama, dipotong 40 karakter', () {
    expect(conversationTitle([{'role': 'assistant', 'text': 'x'}]), 'Percakapan');
    expect(conversationTitle([{'role': 'user', 'text': '  halo   dunia '}]), 'halo dunia');
    final t = conversationTitle([{'role': 'user', 'text': 'a' * 80}]);
    expect(t.length, 41);
    expect(t.endsWith('…'), true);
  });

  test('simpan, urut terbaru, hapus, dan batas jumlah', () async {
    SharedPreferences.setMockInitialValues({});
    SavedConversation c(String id, int t) => SavedConversation(id: id, title: id, updated: t, lines: const [], convo: const []);
    await ConversationStore.add(c('a', 1));
    await ConversationStore.add(c('b', 2));
    expect((await ConversationStore.all()).map((e) => e.id).toList(), ['b', 'a']);
    await ConversationStore.remove('b');
    expect((await ConversationStore.all()).single.id, 'a');
    for (var i = 0; i < 60; i++) {
      await ConversationStore.add(c('n$i', 100 + i));
    }
    expect((await ConversationStore.all()).length, ConversationStore.maxItems);
  });

  test('data rusak tidak membuat aplikasi gagal', () async {
    SharedPreferences.setMockInitialValues({'neuron.conversations.v1': '{bukan json'});
    expect(await ConversationStore.all(), isEmpty);
  });

  test('round trip JSON', () {
    const c = SavedConversation(id: '1', title: 't', updated: 5, lines: [{'role': 'user', 'text': 'q'}], convo: [{'role': 'user', 'content': 'q'}]);
    final back = SavedConversation.fromJson(c.toJson());
    expect(back.lines.single['text'], 'q');
    expect(back.convo.single['content'], 'q');
  });
}
