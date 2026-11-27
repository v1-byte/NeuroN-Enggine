import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Judul otomatis dari pesan pengguna pertama (maks 40 karakter).
String conversationTitle(List<Map<String, String>> lines) {
  for (final l in lines) {
    if (l['role'] == 'user') {
      final t = (l['text'] ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isEmpty) continue;
      return t.length > 40 ? '${t.substring(0, 40).trimRight()}…' : t;
    }
  }
  return 'Percakapan';
}

class SavedConversation {
  const SavedConversation({required this.id, required this.title, required this.updated, required this.lines, required this.convo});
  final String id;
  final String title;
  final int updated; // epoch ms
  final List<Map<String, String>> lines; // {role,text}
  final List<Map<String, String>> convo; // {role,content}

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'updated': updated, 'lines': lines, 'convo': convo};

  static List<Map<String, String>> _rows(Object? v) => ((v as List?) ?? const [])
      .whereType<Map>()
      .map((m) => m.map((k, v) => MapEntry('$k', '$v')))
      .toList();

  factory SavedConversation.fromJson(Map<String, dynamic> j) => SavedConversation(
        id: '${j['id']}',
        title: '${j['title'] ?? 'Percakapan'}',
        updated: (j['updated'] as num?)?.toInt() ?? 0,
        lines: _rows(j['lines']),
        convo: _rows(j['convo']),
      );
}

/// Arsip percakapan di penyimpanan privat aplikasi (SharedPreferences). Maksimum 50 percakapan terbaru.
class ConversationStore {
  static const _conversationNamespace = 'neuron.conversations.v1';
  static const maxItems = 50;

  static Future<List<SavedConversation>> all() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_conversationNamespace);
      if (raw == null) return [];
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => SavedConversation.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      list.sort((a, b) => b.updated.compareTo(a.updated));
      return list;
    } catch (_) {
      return []; // data rusak diabaikan, bukan membuat aplikasi gagal
    }
  }

  static Future<void> _save(List<SavedConversation> items) async {
    final trimmed = items.take(maxItems).map((e) => e.toJson()).toList();
    await (await SharedPreferences.getInstance()).setString(_conversationNamespace, jsonEncode(trimmed));
  }

  static Future<void> add(SavedConversation c) async {
    final items = await all();
    items.removeWhere((e) => e.id == c.id);
    items.insert(0, c);
    await _save(items);
  }

  static Future<void> remove(String id) async {
    final items = await all();
    items.removeWhere((e) => e.id == id);
    await _save(items);
  }

  static Future<void> clear() async => (await SharedPreferences.getInstance()).remove(_conversationNamespace);
}
