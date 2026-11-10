import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_pages.dart';
import 'bridge.dart';
import 'chat_pane.dart';
import 'code_editor.dart';
import 'dialogs.dart';
import 'feature_workspace.dart';
import 'inspector.dart';
import 'theme.dart';

void main() => runApp(const NeuraApp());

class NeuraApp extends StatelessWidget {
  const NeuraApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'NeuroN Engine',
        debugShowCheckedModeBanner: false,
        theme: neuronTheme(),
        home: const NeuraHome(),
      );
}

/// Riwayat ubahan satu berkas untuk undo/redo. Ketikan beruntun dalam 600 ms dihitung satu langkah.
class EditHistory {
  EditHistory(this._current);

  String _current;
  final List<String> _past = [];
  final List<String> _future = [];
  DateTime _lastEdit = DateTime.fromMillisecondsSinceEpoch(0);

  static const _limit = 300;

  String get current => _current;
  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  void push(String text) {
    if (text == _current) return;
    final now = DateTime.now();
    if (now.difference(_lastEdit).inMilliseconds > 600) {
      _past.add(_current);
      if (_past.length > _limit) _past.removeAt(0);
    }
    _future.clear();
    _current = text;
    _lastEdit = now;
  }

  String? undo() {
    if (_past.isEmpty) return null;
    _future.add(_current);
    _current = _past.removeLast();
    _lastEdit = DateTime.fromMillisecondsSinceEpoch(0);
    return _current;
  }

  String? redo() {
    if (_future.isEmpty) return null;
    _past.add(_current);
    _current = _future.removeLast();
    _lastEdit = DateTime.fromMillisecondsSinceEpoch(0);
    return _current;
  }
}

bool _jsonValid(String s) {
  try {
    jsonDecode(s);
    return true;
  } catch (_) {
    return false;
  }
}

class NeuraHome extends StatefulWidget {
  const NeuraHome({super.key});
  @override
  State<NeuraHome> createState() => _NeuraHomeState();
}

class _NeuraHomeState extends State<NeuraHome> with WidgetsBindingObserver {
  static const _chatPath = 'chat/params.json';

  final _editor = TextEditingController();
  final _chatInput = TextEditingController();
  final _find = TextEditingController();
  final _replace = TextEditingController();

  // Berkas: 17 berkas virtual dari VirtualTree. Teks dibaca saat pertama dibuka.
  List<String> _paths = [];
  String? _active;
  final Map<String, EditHistory> _hist =
      {}; // teks sekarang + riwayat undo per berkas
  final Map<String, String> _saved =
      {}; // teks terakhir yang tersimpan di proyek
  final Map<String, String> _drafts = {};
  Timer? _draftTimer;
  Future<void> _draftWriteQueue = Future<void>.value();

  bool _ready = false;
  bool _findOpen = false;
  String _section = 'Beranda';
  EngineSettings? _dashboardEngine;
  bool _serverRunning = false;
  List<String> _knowledgeFiles = [];
  int _knowledgeChunks = 0;
  bool _ragEnabled = false;
  String _mode =
      'Kode'; // 'Kode' | 'Inspektur' (Inspektur hanya untuk chat/params.json)
  String? _workspacePage;
  String _engineStatus = 'Memuat…';

  // Riwayat tampilan dan konteks percakapan API disimpan di penyimpanan privat Android.
  final List<ChatLine> _lines = [];
  final List<Map<String, String>> _convo = [];
  final StringBuffer _reply = StringBuffer();
  Future<void> _chatWriteQueue = Future<void>.value();
  StreamSubscription<dynamic>? _chatSub;
  bool _streaming = false;
  bool _clearingChat = false;

  final List<String> _logs = [];

  // ---------- Siklus hidup ----------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _flushPendingDraft();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chatSub?.cancel();
    _flushPendingDraft();
    _editor.dispose();
    _chatInput.dispose();
    _find.dispose();
    _replace.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final paths = await Bridge.openPaths();
      ChatHistory? history;
      Map<String, String> drafts = {};
      try {
        history = await Bridge.loadChatHistory();
      } catch (e) {
        _log('WARN', 'Riwayat chat tidak bisa dimuat: $e');
      }
      try {
        drafts = await Bridge.loadDrafts();
      } catch (e) {
        _log('WARN', 'Draft editor tidak bisa dimuat: $e');
      }
      if (!mounted) return;
      setState(() {
        _paths = paths;
        _drafts.addAll(drafts);
        if (history != null) {
          _lines.addAll(history.lines.map((row) =>
              ChatLine(row['role'] ?? 'assistant', row['text'] ?? '')));
          _convo.addAll(history.conversation);
        }
        _ready = true;
      });
      _log('INFO', 'Proyek dibuka, ${paths.length} berkas');
      await _open(_chatPath);
      await _refreshEngine();
      await _refreshDashboardData();
    } catch (e) {
      _log('ERROR', 'Proyek tidak bisa dibuka: $e');
      toast('Proyek tidak bisa dibuka');
    }
  }

  // ---------- Utilitas ----------

  void toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2)));
  }

  void _log(String level, String text) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final entry =
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)} $level  $text';
    if (!mounted) {
      _logs.add(entry);
      return;
    }
    setState(() => _logs.add(entry));
  }

  // ---------- Berkas ----------

  EditHistory? get _h => _active == null ? null : _hist[_active];
  String get _text => _h?.current ?? '';
  bool get _activeIsJson => _active?.endsWith('.json') ?? false;
  bool _isDirty(String path) =>
      _hist[path] != null && _hist[path]!.current != (_saved[path] ?? '');
  bool get _dirtyActive => _active != null && _isDirty(_active!);

  Future<void> _open(String path) async {
    if (_draftTimer?.isActive == true && _active != null) {
      _draftTimer!.cancel();
      _enqueueDraftSave(_active!, _text);
    }
    if (!_hist.containsKey(path)) {
      try {
        final text = await Bridge.read(path);
        _saved[path] = text;
        final draft = _drafts[path];
        _hist[path] =
            EditHistory(draft != null && draft != text ? draft : text);
      } catch (e) {
        _log('ERROR', 'Gagal membaca $path: $e');
        toast('Gagal membaca $path');
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _active = path;
      _findOpen = false;
      if (path != _chatPath) _mode = 'Kode';
    });
    _syncEditor();
  }

  /// Menyalin teks berkas aktif ke controller editor (tanpa memicu onChanged).
  void _syncEditor() {
    final t = _text;
    _editor.value = TextEditingValue(
        text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  /// Ketikan pengguna di editor.
  void _onEdit(String text) {
    final h = _h;
    if (h == null) return;
    h.push(text);
    final path = _active;
    if (path != null) _scheduleDraftSave(path, text);
    setState(() {});
  }

  /// Perubahan dari luar editor (rapikan, ganti semua, inspektur). Masuk riwayat undo.
  void _applyText(String text) {
    final h = _h;
    if (h == null || text == h.current) return;
    h.push(text);
    final path = _active;
    if (path != null) _scheduleDraftSave(path, text);
    _syncEditor();
    setState(() {});
  }

  void _undo() {
    final t = _h?.undo();
    if (t == null) return;
    final path = _active;
    if (path != null) _scheduleDraftSave(path, t);
    _syncEditor();
    setState(() {});
  }

  void _redo() {
    final t = _h?.redo();
    if (t == null) return;
    final path = _active;
    if (path != null) _scheduleDraftSave(path, t);
    _syncEditor();
    setState(() {});
  }

  Future<void> _save() async {
    final path = _active;
    if (path == null) return;
    final text = _text;
    try {
      _draftTimer?.cancel();
      await _draftWriteQueue;
      await Bridge.write(path, text);
      if (!mounted) return;
      setState(() {
        _saved[path] = text;
        _drafts.remove(path);
      });
      _log('INFO', 'Tersimpan: $path');
      toast('Tersimpan');
      if (path == 'engine/api.json') {
        // Kunci API dipindah ke penyimpanan terenkripsi; muat ulang berkas agar editor tidak memegang kunci.
        _hist.remove(path);
        _saved.remove(path);
        await _open(path);
        await _refreshEngine();
      }
    } catch (e) {
      final msg = e is PlatformException ? (e.message ?? e.code) : '$e';
      _log('ERROR', 'Gagal menyimpan $path: $msg');
      toast('Tidak tersimpan: $msg');
    }
  }

  void _scheduleDraftSave(String path, String text) {
    if (path == 'engine/api.json') {
      return; // bisa berisi kunci; simpan lewat SecretStore terenkripsi.
    }
    _drafts[path] = text;
    _draftTimer?.cancel();
    _draftTimer = Timer(
        const Duration(milliseconds: 500), () => _enqueueDraftSave(path, text));
  }

  void _flushPendingDraft() {
    if (_draftTimer?.isActive != true || _active == null) return;
    _draftTimer!.cancel();
    _enqueueDraftSave(_active!, _text);
  }

  void _enqueueDraftSave(String path, String text) {
    if (path == 'engine/api.json') return;
    _draftWriteQueue = _draftWriteQueue.then((_) async {
      try {
        await Bridge.saveDraft(path, text);
      } catch (e) {
        _log('ERROR', 'Draft $path gagal disimpan: $e');
      }
    });
  }

  void _format() {
    if (!_activeIsJson) return;
    try {
      _applyText(const JsonEncoder.withIndent('  ').convert(jsonDecode(_text)));
      toast('JSON dirapikan');
    } catch (_) {
      toast('JSON tidak valid');
    }
  }

  void _replaceAll() {
    final needle = _find.text;
    if (needle.isEmpty) return;
    final parts = _text.split(needle);
    final count = parts.length - 1;
    if (count == 0) {
      toast('Tidak ditemukan');
      return;
    }
    _applyText(parts.join(_replace.text));
    toast('$count diganti');
  }

  // ---------- Engine dan chat ----------

  Future<void> _refreshEngine() async {
    try {
      final e = await Bridge.loadEngine();
      if (!mounted) return;
      setState(() {
        _dashboardEngine = e;
        _engineStatus = e.mode == 'LOCAL'
            ? (e.nativeAvailable
                ? 'Lokal · ${e.modelPath.split('/').last}'
                : 'Lokal · native belum tersedia')
            : (e.baseUrl.isEmpty || e.model.isEmpty)
                ? 'API belum dikonfigurasi'
                : 'API · ${e.model}';
      });
    } catch (e) {
      _log('ERROR', 'Gagal memuat pengaturan API: $e');
    }
  }

  Future<void> _refreshDashboardData() async {
    try {
      final values = await Future.wait<dynamic>([
        Bridge.knowledgeState(),
        Bridge.serverState(),
      ]);
      if (!mounted) return;
      final rag = Map<String, dynamic>.from(values[0] as Map);
      final server = Map<String, dynamic>.from(values[1] as Map);
      setState(() {
        _knowledgeFiles = ((rag['files'] as List?) ?? const [])
            .map((file) => file.toString())
            .toList();
        _knowledgeChunks = (rag['chunks'] as num?)?.toInt() ?? 0;
        _ragEnabled = rag['enabled'] == true;
        _serverRunning = server['running'] == true;
      });
    } catch (_) {
      // Some bridge actions are not available during early app startup.
    }
  }

  void _send() {
    final q = _chatInput.text.trim();
    if (q.isEmpty || _streaming || _clearingChat) return;
    _convo.add({'role': 'user', 'content': q});
    _reply.clear();
    _chatInput.clear();
    setState(() {
      _lines.add(ChatLine('user', q));
      _lines.add(const ChatLine('assistant', ''));
      _streaming = true;
    });
    _log('INFO', 'Chat dikirim ($_engineStatus)');

    _chatSub = Bridge.chat(List<Map<String, String>>.of(_convo)).listen(
      (token) {
        _reply.write(token as String);
        if (!mounted) return;
        setState(() => _lines[_lines.length - 1] =
            ChatLine('assistant', _reply.toString()));
      },
      onError: (Object e) =>
          _finish(error: e is PlatformException ? (e.message ?? e.code) : '$e'),
      onDone: () => _finish(),
    );
  }

  Future<void> _stop() async {
    final sub = _chatSub;
    _chatSub = null;
    await sub?.cancel();
    _finish(stopped: true);
  }

  void _finish({String? error, bool stopped = false}) {
    if (!_streaming) {
      return; // onError dan onDone bisa sama-sama terpanggil; cukup satu kali
    }
    _chatSub = null;
    final partial = _reply.toString();
    final last = _lines.length - 1;
    setState(() {
      _streaming = false;
      if (error != null) {
        if (_convo.isNotEmpty) {
          _convo.removeLast(); // giliran yang gagal tidak ikut dikirim ulang
        }
        _lines[last] =
            ChatLine('error', partial.isEmpty ? error : '$partial\n\n⚠ $error');
      } else {
        if (partial.isNotEmpty) {
          _convo.add({'role': 'assistant', 'content': partial});
        }
        _lines[last] = ChatLine(
          'assistant',
          partial.isEmpty
              ? '(tidak ada jawaban)'
              : (stopped ? '$partial\n\n[dihentikan]' : partial),
        );
      }
    });
    unawaited(_persistChat());
    if (error != null) {
      _log('ERROR', 'Chat gagal: $error');
    } else {
      _log('INFO', stopped ? 'Generate dihentikan' : 'Jawaban selesai');
    }
  }

  Future<void> _persistChat() {
    final snapshot = ChatHistory(
      lines: _lines
          .map((line) => {'role': line.role, 'text': line.text})
          .toList(growable: false),
      conversation: _convo
          .map((message) => Map<String, String>.from(message))
          .toList(growable: false),
    );
    _chatWriteQueue = _chatWriteQueue.then((_) async {
      try {
        await Bridge.saveChatHistory(snapshot);
      } catch (e) {
        _log('ERROR', 'Riwayat chat gagal disimpan: $e');
      }
    });
    return _chatWriteQueue;
  }

  // ---------- Dialog ----------

  Future<void> _openEngine() async {
    try {
      final current = await Bridge.loadEngine();
      if (!mounted) return;
      final next = await showEngineDialog(context, current);
      if (next == null) return;
      await Bridge.saveEngine(next);
      _log('INFO', 'Pengaturan API disimpan');
      toast('Pengaturan API disimpan');
      await _refreshEngine();
    } catch (e) {
      _log('ERROR', 'Simpan pengaturan API gagal: $e');
      toast('Gagal menyimpan pengaturan');
    }
  }

  Future<void> _openFeatures() async {
    try {
      final s = await Bridge.loadFeatures();
      if (!mounted) return;
      await showFeaturesDialog(context, s, _log);
    } catch (e) {
      _log('ERROR', 'Gagal memuat fitur: $e');
      toast('Fitur tidak bisa dimuat');
    }
  }

  void _openWorkspace(String page) => setState(() {
        _section = 'Workspace';
        _workspacePage = page;
      });

  void _goTo(String section) {
    setState(() {
      _section = section;
      if (section == 'Workspace') _workspacePage = null;
    });
    if (section == 'Beranda' || section == 'Library') {
      _refreshDashboardData();
      _refreshEngine();
    }
  }

  Future<void> _showImportTargets() async {
    final target = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: panel,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Pilih tujuan import',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.memory_outlined, color: blue),
              title: const Text('Model lokal · GGUF'),
              subtitle: const Text('Pilih model untuk engine lokal'),
              onTap: () => Navigator.pop(ctx, 'Model lokal'),
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined, color: purple),
              title: const Text('Knowledge / RAG'),
              subtitle: const Text('Tambahkan dokumen pengetahuan'),
              onTap: () => Navigator.pop(ctx, 'Data & RAG'),
            ),
            const ListTile(
              leading: Icon(Icons.table_chart_outlined, color: muted),
              title: Text('Dataset training'),
              subtitle: Text('Import dataset belum tersedia di UI'),
              enabled: false,
            ),
          ]),
        ),
      ),
    );
    if (target != null) _openWorkspace(target);
  }

  Future<void> _clearChat() async {
    if (_streaming || _clearingChat) return;
    setState(() => _clearingChat = true);
    try {
      await _chatWriteQueue;
      await Bridge.clearChatHistory();
      if (!mounted) return;
      setState(() {
        _lines.clear();
        _convo.clear();
        _clearingChat = false;
      });
      _log('INFO', 'Riwayat chat dihapus dari perangkat');
      toast('Riwayat chat dihapus');
    } catch (e) {
      if (mounted) setState(() => _clearingChat = false);
      _log('ERROR', 'Gagal menghapus riwayat chat: $e');
      toast('Riwayat chat tidak berhasil dihapus');
    }
  }

  Future<void> _showWorkspaceFiles() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: panel,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Text('File Workspace',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            for (final path in _paths)
              ListTile(
                dense: true,
                selected: path == _active,
                leading: Icon(
                  path.endsWith('.json')
                      ? Icons.data_object_outlined
                      : Icons.description_outlined,
                  color: path == _active ? blue : muted,
                ),
                title: Text(path.split('/').last),
                subtitle: Text(path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : 'Project'),
                trailing: path == _active
                    ? const Icon(Icons.check, color: blue, size: 18)
                    : null,
                onTap: () => Navigator.pop(ctx, path),
              ),
          ],
        ),
      ),
    );
    if (selected != null) await _open(selected);
  }

  Widget _workspaceStatus() {
    return FeatureWorkspace(
      key: ValueKey(_workspacePage),
      page: _workspacePage ?? '',
      onLog: _log,
      onBack: () {
        setState(() => _workspacePage = null);
        _refreshEngine();
        _refreshDashboardData();
      },
    );
  }

  Widget _editorHeader() => Container(
        height: 62,
        color: panel,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: const Color(0xFF1C2C42),
                borderRadius: BorderRadius.circular(11)),
            child: const Icon(Icons.folder_open_outlined, color: blue, size: 19),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Workspace',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                Text(_active ?? 'Pilih file project',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 10)),
              ],
            ),
          ),
          if (_dirtyActive)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.circle, color: amber, size: 8),
            ),
          IconButton(
            tooltip: 'Pilih file project',
            onPressed: _showWorkspaceFiles,
            icon: const Icon(Icons.folder_copy_outlined, color: blue),
          ),
        ]),
      );

  // ---------- Tampilan ----------

  int get _pageIndex => switch (_section) {
        'Beranda' => 0,
        'Chat' => 1,
        'Library' => 2,
        'Import' => 3,
        'Lainnya' => 4,
        'Workspace' => 5,
        'Activity' => 6,
        _ => 0,
      };

  int get _navigationIndex => switch (_section) {
        'Beranda' => 0,
        'Chat' => 1,
        'Library' => 2,
        'Import' => 3,
        _ => 4,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          _header(),
          Expanded(
            child: IndexedStack(
              index: _pageIndex,
              children: [
                _dashboardPage(),
                _chatPage(),
                _libraryPage(),
                _importPage(),
                _morePage(),
                _workspaceEditorPage(),
                ActivityPage(logs: List<String>.of(_logs)),
              ],
            ),
          ),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _navigationIndex,
        onDestinationSelected: (index) => _goTo(const [
          'Beranda',
          'Chat',
          'Library',
          'Import',
          'Lainnya',
        ][index]),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Beranda'),
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Chat'),
          NavigationDestination(
              icon: Icon(Icons.inventory_2_outlined),
              selectedIcon: Icon(Icons.inventory_2),
              label: 'Library'),
          NavigationDestination(
              icon: Icon(Icons.file_upload_outlined),
              selectedIcon: Icon(Icons.file_upload),
              label: 'Import'),
          NavigationDestination(
              icon: Icon(Icons.apps_outlined),
              selectedIcon: Icon(Icons.apps),
              label: 'Lainnya'),
        ],
      ),
    );
  }

  Widget _dashboardPage() => DashboardPage(
        engineStatus: _engineStatus,
        serverRunning: _serverRunning,
        ragEnabled: _ragEnabled,
        documentCount: _knowledgeFiles.length,
        chunkCount: _knowledgeChunks,
        recentLogs: _logs.reversed.take(3).toList(),
        onChat: () => _goTo('Chat'),
        onImport: () => _goTo('Import'),
        onLibrary: () => _goTo('Library'),
        onSettings: _openEngine,
        onWorkspace: () => _goTo('Workspace'),
        onActivity: () => _goTo('Activity'),
      );

  Widget _chatPage() => Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 13, 10, 12),
          decoration: const BoxDecoration(
              color: panel,
              border: Border(bottom: BorderSide(color: line))),
          child: Row(children: [
            const Icon(Icons.circle, size: 8, color: blue),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                const Text('Percakapan',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                Text(_engineStatus,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 10)),
              ]),
            ),
            IconButton(
              tooltip: 'Atur engine',
              onPressed: _openEngine,
              icon: const Icon(Icons.tune, size: 19),
            ),
            IconButton(
              tooltip: 'Percakapan baru',
              onPressed: _streaming || _clearingChat ? null : _clearChat,
              icon: const Icon(Icons.add_comment_outlined, size: 19),
            ),
          ]),
        ),
        Expanded(
          child: ChatPane(
            lines: _lines,
            streaming: _streaming,
            input: _chatInput,
            onSend: _send,
            onStop: _stop,
            hint: _engineStatus.startsWith('API belum')
                ? 'Konfigurasikan Base URL dan model terlebih dahulu untuk memulai chat.'
                : 'Mulai percakapan dengan mengirim pesan.',
          ),
        ),
      ]);

  Widget _libraryPage() => LibraryPage(
        engine: _dashboardEngine,
        knowledgeFiles: _knowledgeFiles,
        chunkCount: _knowledgeChunks,
        onImport: () => _goTo('Import'),
        onModelSettings: () => _openWorkspace('Model lokal'),
        onKnowledgeSettings: () => _openWorkspace('Data & RAG'),
      );

  Widget _importPage() => ImportCenterPage(
        onDevice: _showImportTargets,
        onHuggingFace: () => _openWorkspace('Hugging Face'),
        onLibrary: () => _goTo('Library'),
      );

  Widget _morePage() => MorePage(
        onWorkspace: () {
          setState(() {
            _section = 'Workspace';
            _workspacePage = null;
          });
        },
        onActivity: () => _goTo('Activity'),
        onSettings: _openEngine,
        onFeatures: _openFeatures,
        onOpenTool: _openWorkspace,
      );

  Widget _workspaceEditorPage() {
    if (_workspacePage != null) return _workspaceStatus();
    return Column(children: [
      _editorHeader(),
      _toolbar(),
      if (_findOpen && _mode == 'Kode') _findBar(),
      Expanded(child: _mainArea()),
      _statusBar(),
    ]);
  }

  Widget _header() => Container(
        height: 62,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        color: panel,
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(11)),
            child: Image.asset('assets/images/neuron_mark.png',
                fit: BoxFit.contain, semanticLabel: 'Logo NeuroN Engine'),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('NeuroN Engine',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                Row(children: [
                  Icon(Icons.circle,
                      size: 6,
                      color: (_engineStatus.startsWith('API ·') ||
                              _engineStatus.startsWith('Lokal ·'))
                          ? green
                          : muted),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      _engineStatus,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted, fontSize: 10),
                    ),
                  ),
                ]),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Pengaturan engine',
            onPressed: _openEngine,
            icon: const Icon(Icons.settings_outlined, color: muted),
          ),
        ]),
      );

  Widget _toolbar() {
    final editing = _mode == 'Kode';
    return Container(
      height: 48,
      color: panel,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 500;
        return Row(children: [
          if (_active == _chatPath)
            _modeSelector(compact: compact)
          else
            const SizedBox(width: 4),
          _tool(Icons.undo_rounded, 'Undo',
              (_h?.canUndo ?? false) ? _undo : null),
          _tool(Icons.redo_rounded, 'Redo',
              (_h?.canRedo ?? false) ? _redo : null),
          _tool(
              Icons.search_rounded,
              'Cari dan ganti',
              (editing && _active != null)
                  ? () => setState(() => _findOpen = !_findOpen)
                  : null),
          const Spacer(),
          if (editing && _activeIsJson)
            compact
                ? _tool(Icons.auto_fix_high_rounded, 'Rapikan JSON', _format)
                : FilledButton.icon(
                    onPressed: _format,
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                    label:
                        const Text('Rapikan', style: TextStyle(fontSize: 10)),
                    style: FilledButton.styleFrom(
                        backgroundColor: panel2,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 34),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10))),
                  ),
          const SizedBox(width: 4),
          if (compact)
            _tool(Icons.save_outlined, 'Simpan', _dirtyActive ? _save : null)
          else
            FilledButton.icon(
              onPressed: _dirtyActive ? _save : null,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('Simpan', style: TextStyle(fontSize: 10)),
              style: FilledButton.styleFrom(
                  backgroundColor: blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 34),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
            ),
        ]);
      }),
    );
  }

  Widget _modeSelector({bool compact = false}) => SegmentedButton<String>(
        segments: [
          ButtonSegment(
              value: 'Kode',
              label: compact ? const SizedBox.shrink() : const Text('Kode'),
              icon: const Icon(Icons.code_rounded)),
          ButtonSegment(
              value: 'Inspektur',
              label:
                  compact ? const SizedBox.shrink() : const Text('Inspektur'),
              icon: const Icon(Icons.tune_rounded)),
        ],
        selected: {_mode},
        showSelectedIcon: false,
        onSelectionChanged: (s) => setState(() {
          _mode = s.first;
          if (_mode == 'Inspektur') _findOpen = false;
        }),
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding:
              const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
          minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
          textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 10)),
          shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        ),
      );

  Widget _tool(IconData icon, String label, VoidCallback? action) => IconButton(
        tooltip: label,
        onPressed: action,
        icon: Icon(icon, size: 17),
        color: muted,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
      );

  Widget _findBar() => Container(
        color: panel2,
        padding: const EdgeInsets.all(7),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _find,
              decoration:
                  const InputDecoration(hintText: 'Cari', isDense: true),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: TextField(
              controller: _replace,
              decoration: const InputDecoration(
                  hintText: 'Ganti dengan', isDense: true),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
              onPressed: _replaceAll,
              child: const Text('Ganti semua', style: TextStyle(fontSize: 10))),
        ]),
      );

  Widget _mainArea() {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    if (_active == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.folder_open_outlined, color: muted, size: 32),
            const SizedBox(height: 10),
            const Text('Mulai dari file project',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 5),
            const Text('Pilih file konfigurasi untuk dilihat atau diedit.',
                textAlign: TextAlign.center,
                style: TextStyle(color: muted, fontSize: 11)),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _showWorkspaceFiles,
              icon: const Icon(Icons.folder_copy_outlined, size: 17),
              label: const Text('Pilih file'),
            ),
          ]),
        ),
      );
    }
    if (_mode == 'Inspektur' && _active == _chatPath) {
      return ParamInspector(text: _text, onChanged: _applyText);
    }
    return CodeEditor(controller: _editor, onChanged: _onEdit);
  }

  Widget _statusBar() {
    final valid = _activeIsJson ? _jsonValid(_text) : null;
    return Container(
      height: 28,
      color: const Color(0xFF15335A),
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: Row(children: [
        Flexible(
          child: Text(
            _active ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10),
          ),
        ),
        const SizedBox(width: 10),
        if (valid != null)
          Text(
            valid ? 'JSON valid' : 'JSON error',
            style: TextStyle(
                color: valid ? green : Colors.redAccent, fontSize: 10),
          ),
        const Spacer(),
        Text('${_text.split('\n').length} baris',
            style: const TextStyle(fontSize: 9, color: Colors.white70)),
      ]),
    );
  }

}
