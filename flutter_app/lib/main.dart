import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_pages.dart';
import 'bridge.dart';
import 'chat_pane.dart';
import 'code_editor.dart';
import 'command_palette.dart';
import 'problems_panel.dart';
import 'syntax_highlight.dart';
import 'tab_session.dart';
import 'app_info.dart';
import 'conversation_store.dart';
import 'dialogs.dart';
import 'edit_history.dart';
import 'model_profile_fill.dart';
import 'model_selector.dart';
import 'errors.dart';
import 'feature_workspace.dart';
import 'inspector.dart';
import 'onboarding.dart';
import 'theme.dart';
import 'tutorial.dart';

void main() => runApp(const NeuraApp());

class NeuraApp extends StatefulWidget {
  const NeuraApp({super.key});
  @override
  State<NeuraApp> createState() => _NeuraAppState();
}

class _NeuraAppState extends State<NeuraApp> {
  NeuronThemePreset _theme = NeuronThemePreset.midnight;

  @override
  void initState() {
    super.initState();
    _restoreTheme();
  }

  Future<void> _restoreTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt('neuron_theme_preset');
    if (!mounted || index == null || index < 0 || index >= NeuronThemePreset.values.length) return;
    setState(() => _theme = NeuronThemePreset.values[index]);
  }

  Future<void> _changeTheme(NeuronThemePreset value) async {
    setState(() => _theme = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('neuron_theme_preset', value.index);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'NeuroN Engine',
        debugShowCheckedModeBanner: false,
        theme: neuronTheme(_theme),
        home: NeuraHome(
          themePreset: _theme,
          onThemeChanged: _changeTheme,
        ),
      );
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
  const NeuraHome({super.key, required this.themePreset, required this.onThemeChanged});
  final NeuronThemePreset themePreset;
  final ValueChanged<NeuronThemePreset> onThemeChanged;
  @override
  State<NeuraHome> createState() => _NeuraHomeState();
}

class _NeuraHomeState extends State<NeuraHome> with WidgetsBindingObserver {
  static const _chatPath = 'chat/params.json';

  final _editor = SyntaxController();
  bool _problemsOpen = false;
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
  bool _restoringTabs = false;
  Future<void> _draftWriteQueue = Future<void>.value();

  bool _ready = false;
  bool _findOpen = false;
  String _section = 'Beranda';
  EngineSettings? _dashboardEngine;
  List<String> _knowledgeFiles = [];
  int _knowledgeChunks = 0;
  bool _ragEnabled = false;
  String _mode =
      'Kode'; // 'Kode' | 'Inspektur' (Inspektur hanya untuk chat/params.json)
  String? _workspacePage;
  String _hubAutoStart = '';
  String _editModelPath = '';
  String? _statsLabel;
  int _tokCount = 0;
  DateTime? _firstTokenAt;
  DateTime? _lastTokenAt;
  String _copilotComplaint = '';
  String _copilotSample = '';
  String _engineStatus = 'Memuat…';
  List<Map<String, dynamic>> _localModels = [];
  bool _modelBusy = false;

  // Riwayat tampilan dan konteks percakapan disimpan di penyimpanan privat Android.
  final List<ChatLine> _lines = [];
  final List<Map<String, String>> _convo = [];
  final StringBuffer _reply = StringBuffer();
  Future<void> _chatWriteQueue = Future<void>.value();
  StreamSubscription<dynamic>? _chatSub;
  Timer? _replyRenderTimer;
  bool _replyRenderPending = false;
  bool _streaming = false;
  bool _clearingChat = false;
  // Peringatan non-fatal dari engine untuk permintaan chat terakhir (RAG dimatikan, template ChatML, riwayat dipangkas).
  final List<String> _chatNotices = [];
  // Batas riwayat yang disimpan di memori dan dikirim lewat bridge; pembatas token yang sebenarnya ada di engine.
  static const _maxConvoMessages = 40;

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
    _replyRenderTimer?.cancel();
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
      await _restoreTabs();
      await _refreshEngine();
      await _refreshDashboardData();
      await _maybeOnboard();
      await _maybeCheckUpdate();
    } catch (e) {
      _log('ERROR', 'Proyek tidak bisa dibuka: $e');
      toast('Proyek tidak bisa dibuka');
    }
  }

  /// Wizard pertama kali, hanya bila belum ada engine yang dikonfigurasi dan belum pernah ditampilkan.
  Future<void> _maybeOnboard() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(kOnboardedKey) == true) return;
      final e = _dashboardEngine;
      final configured = e != null && e.modelPath.isNotEmpty;
      if (configured) {
        await prefs.setBool(kOnboardedKey, true);
        return;
      }
      if (!mounted) return;
      final r = await Navigator.of(context).push<String>(
          MaterialPageRoute(fullscreenDialog: true, builder: (_) => const OnboardingPage()));
      await prefs.setBool(kOnboardedKey, true);
      if (r != null && r.startsWith('download:') && mounted) {
        setState(() {
          _hubAutoStart = r.substring('download:'.length);
          _section = 'Workspace';
          _workspacePage = 'Model Hub';
        });
      }
    } catch (e) {
      _log('WARN', 'Onboarding dilewati: $e');
    }
  }

  Future<void> _maybeCheckUpdate() async {
    try {
      final update = await Bridge.checkForUpdate();
      if (!mounted || update['available'] != true) return;
      final tag = '${update['tag'] ?? 'versi baru'}';
      final size = _formatBytes(update['size']);
      final install = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Update NeuroN tersedia'),
              content: Text('Rilis $tag${size.isEmpty ? '' : ' · $size'} tersedia dari GitHub Releases. Unduh dan lanjutkan ke installer Android?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nanti')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unduh & pasang')),
              ],
            ),
          ) ??
          false;
      if (!install || !mounted) return;
      toast('Mengunduh update…');
      await Bridge.downloadAndInstallUpdate('${update['url']}');
    } catch (e) {
      _log('WARN', 'Pemeriksaan update dilewati: $e');
    }
  }

  String _formatBytes(dynamic value) {
    final n = value is num ? value.toDouble() : 0;
    if (n <= 0) return '';
    if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(1)} GB';
    if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(0)} MB';
    return '${(n / 1e3).toStringAsFixed(0)} KB';
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
    _persistTabs();
  }

  /// Simpan daftar tab dan tab aktif agar pulih saat aplikasi dibuka lagi.
  Future<void> _persistTabs() async {
    if (_restoringTabs) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kTabSessionKey, encodeTabSession(_hist.keys.toList(), _active));
    } catch (e) {
      _log('WARN', 'Tab tidak tersimpan: $e');
    }
  }

  /// Buka kembali tab dari sesi terakhir; bila tidak ada, buka chat/params.json seperti biasa.
  /// Tab yang punya draf belum disimpan ikut pulih lewat draf (lihat _open).
  Future<void> _restoreTabs() async {
    var session = const TabSession([], null);
    try {
      final prefs = await SharedPreferences.getInstance();
      session = decodeTabSession(prefs.getString(kTabSessionKey), _paths);
    } catch (e) {
      _log('WARN', 'Sesi tab tidak bisa dibaca: $e');
    }
    if (session.open.isEmpty) {
      await _open(_chatPath);
      return;
    }
    _restoringTabs = true;
    try {
      for (final p in session.open) {
        await _open(p);
      }
      final a = session.active;
      if (a != null && a != _active && _hist.containsKey(a)) await _open(a);
    } finally {
      _restoringTabs = false;
    }
    if (_hist.isEmpty) await _open(_chatPath);
    await _persistTabs();
  }

  /// Menyalin teks berkas aktif ke controller editor (tanpa memicu onChanged).
  void _syncEditor() {
    final t = _text;
    _editor.language = languageForPath(_active);
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

  /// Isi berkas aktif dari header model GGUF lokal yang aktif. Hasil masuk riwayat undo dan belum tersimpan sampai pengguna menekan Simpan.
  Future<void> _fillFromLocalModel() async {
    final path = _active;
    if (path == null || !canFillFromModel(path)) return;
    try {
      final models = await Bridge.localModels();
      final active = models.where((m) => m['active'] == true).toList();
      if (active.isEmpty) {
        toast(models.isEmpty
            ? 'Belum ada model lokal. Impor atau unduh model dulu.'
            : 'Belum ada model aktif. Aktifkan satu model di Library.');
        return;
      }
      final profile = await Bridge.localModelProfile('${active.first['path']}');
      if (!mounted || _active != path) return;
      final result = fillFromProfile(path, _text, profile);
      final text = result.text;
      if (text != null) {
        _applyText(text);
        _log('INFO', 'Berkas $path diisi dari model ${profile['name']}');
      }
      toast(result.message);
    } catch (e) {
      _log('ERROR', 'Isi dari model lokal gagal: $e');
      toast('Gagal membaca model lokal');
    }
  }

  Future<void> _save() async {
    final path = _active;
    if (path == null) return;
    final text = _text;
    try {
      _draftTimer?.cancel();
      await _draftWriteQueue;
      final warning = await Bridge.write(path, text);
      if (!mounted) return;
      setState(() {
        _saved[path] = text;
        _drafts.remove(path);
      });
      _log('INFO', 'Tersimpan: $path');
      if (warning != null) {
        _log('WARN', warning);
        toast(warning);
      } else {
        toast('Tersimpan');
      }
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
      if (e.legacyApi) {
        toast('Konfigurasi API lama ditemukan dan diabaikan. NeuroN hanya memakai model GGUF lokal.');
        unawaited(Bridge.ackLegacyApi().catchError((Object _) {}));
      }
      setState(() {
        _dashboardEngine = e;
        _engineStatus = e.modelPath.isEmpty
            ? 'Belum ada model lokal'
            : (e.nativeAvailable
                ? 'Lokal · ${e.modelPath.split('/').last}'
                : 'Lokal · native belum tersedia');
      });
      await _refreshLocalModels();
    } catch (e) {
      _log('ERROR', 'Gagal memuat pengaturan engine: $e');
    }
  }

  Future<void> _refreshLocalModels() async {
    try {
      final models = await Bridge.localModels(hash: false);
      if (mounted) setState(() => _localModels = models);
    } catch (e) {
      _log('WARN', 'Daftar model lokal gagal dimuat: $e');
    }
  }

  Future<void> _selectChatModel(String path) async {
    if (_streaming || _modelBusy) {
      toast('Tunggu sampai jawaban selesai sebelum mengganti model.');
      return;
    }
    final chosen = _localModels.where((m) => '${m['path'] ?? ''}' == path).toList();
    final name = chosen.isEmpty ? path.split('/').last : ModelSelector.modelName(chosen.first);
    setState(() => _modelBusy = true);
    try {
      toast('Mengaktifkan $name…');
      final result = await Bridge.activateLocalModel(path);
      if (result['nativeAvailable'] == true) {
        await Bridge.runModel();
      }
      await _refreshEngine();
      await _refreshLocalModels();
      if (!mounted) return;
      toast(result['nativeAvailable'] == true
          ? '$name dipilih untuk Chat. Model dimuat saat pesan dikirim.'
          : '$name dipilih, tetapi library native llama.cpp belum tersedia.');
      _log('INFO', 'Model Chat dipilih: $path');
    } catch (e) {
      _log('ERROR', 'Aktivasi model Chat gagal: $e');
      toast('Model tidak bisa diaktifkan: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _modelBusy = false);
    }
  }

  Future<void> _refreshDashboardData() async {
    try {
      final rag = Map<String, dynamic>.from(await Bridge.knowledgeState());
      if (!mounted) return;
      setState(() {
        _knowledgeFiles = ((rag['files'] as List?) ?? const [])
            .map((file) => file.toString())
            .toList();
        _knowledgeChunks = (rag['chunks'] as num?)?.toInt() ?? 0;
        _ragEnabled = rag['enabled'] == true;
      });
    } catch (_) {
      // Some bridge actions are not available during early app startup.
    }
  }

  void _send() {
    final q = _chatInput.text.trim();
    if (q.isEmpty || _streaming || _clearingChat) return;
    _chatInput.clear();
    _submit(q);
  }

  /// Susun ulang konteks percakapan dari tampilan, hanya sampai [end] (tanpa baris error/penanda berhenti).
  List<Map<String, String>> _convoFromLines(int end) {
    final out = <Map<String, String>>[];
    for (var i = 0; i < end && i < _lines.length; i++) {
      final l = _lines[i];
      if (l.role == 'user') {
        final failed = i + 1 < _lines.length && _lines[i + 1].role == 'error';
        if (!failed) out.add({'role': 'user', 'content': l.text});
      } else if (l.role == 'assistant' && l.text != '(tidak ada jawaban)') {
        out.add({'role': 'assistant', 'content': l.text.replaceFirst(RegExp(r'\n\n\[dihentikan\]$'), '')});
      }
    }
    return out;
  }

  /// Edit pesan pengguna: percakapan dipotong di titik itu, lalu dikirim ulang dengan teks baru.
  Future<void> _editMessage(int index) async {
    if (_streaming || index < 0 || index >= _lines.length || _lines[index].role != 'user') return;
    final ctrl = TextEditingController(text: _lines[index].text);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        title: const Text('Edit pesan'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctrl, autofocus: true, minLines: 2, maxLines: 8),
          const SizedBox(height: 8),
          const Text('Pesan dan jawaban setelahnya akan diganti dengan jawaban baru.', style: TextStyle(fontSize: 11, color: muted)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Kirim ulang')),
        ],
      ),
    );
    ctrl.dispose();
    if (text == null || text.isEmpty || !mounted) return;
    _resendFrom(index, text);
  }

  /// Ulangi jawaban terakhir dari pertanyaan pengguna sebelumnya.
  void _regenerate(int index) {
    if (_streaming || index != _lines.length - 1) return;
    for (var i = index - 1; i >= 0; i--) {
      if (_lines[i].role == 'user') {
        _resendFrom(i, _lines[i].text);
        return;
      }
    }
  }

  void _resendFrom(int index, String text) {
    final history = _convoFromLines(index);
    _convo
      ..clear()
      ..addAll(history);
    setState(() => _lines.removeRange(index, _lines.length));
    _submit(text);
  }

  /// Batasi riwayat percakapan: buang yang terlama dan pastikan dimulai dari pesan pengguna.
  void _boundConvo() {
    if (_convo.length > _maxConvoMessages) {
      _convo.removeRange(0, _convo.length - _maxConvoMessages);
    }
    while (_convo.length > 1 && _convo.first['role'] != 'user') {
      _convo.removeAt(0);
    }
  }

  void _submit(String q) {
    if (_streaming || _clearingChat) return;
    final previous = _chatSub;
    _chatSub = null;
    unawaited(previous?.cancel());
    _convo.add({'role': 'user', 'content': q});
    _boundConvo();
    _chatNotices.clear();
    _reply.clear();
    _tokCount = 0;
    _firstTokenAt = null;
    _lastTokenAt = null;
    _statsLabel = null;
    setState(() {
      _lines.add(ChatLine('user', q));
      _lines.add(const ChatLine('assistant', ''));
      _streaming = true;
    });
    _log('INFO', 'Chat dikirim ($_engineStatus)');

    _chatSub = Bridge.chat(List<Map<String, String>>.of(_convo)).listen(
      (event) {
        if (event is Map) {
          // Peringatan non-fatal dari engine, bukan token jawaban.
          final text = event['text'];
          if (event['type'] == 'notice' && text is String && text.isNotEmpty && mounted) {
            if (!_chatNotices.contains(text)) setState(() => _chatNotices.add(text));
            _log('WARN', text);
          }
          return;
        }
        final token = event as String;
        _reply.write(token);
        _tokCount++;
        final now = DateTime.now();
        _firstTokenAt ??= now;
        _lastTokenAt = now;
        _scheduleReplyRender();
      },
      onError: (Object e) => _finish(error: e),
      onDone: () => _finish(),
    );
  }

  Future<void> _stop() async {
    final sub = _chatSub;
    _chatSub = null;
    await sub?.cancel();
    _finish(stopped: true);
  }

  /// Token native bisa datang jauh lebih cepat daripada frame UI. Buffer tetap
  /// menerima semua token, tetapi tampilan cukup diperbarui paling banyak 20x/dtk.
  void _scheduleReplyRender() {
    if (_replyRenderPending || !mounted) return;
    _replyRenderPending = true;
    _replyRenderTimer = Timer(const Duration(milliseconds: 50), () {
      _replyRenderPending = false;
      _replyRenderTimer = null;
      if (!mounted || !_streaming || _lines.isEmpty) return;
      setState(() => _lines[_lines.length - 1] = ChatLine('assistant', _reply.toString()));
    });
  }

  void _finish({Object? error, bool stopped = false}) {
    if (!_streaming) {
      return; // onError dan onDone bisa sama-sama terpanggil; cukup satu kali
    }
    _chatSub = null;
    _replyRenderTimer?.cancel();
    _replyRenderTimer = null;
    _replyRenderPending = false;
    final partial = _reply.toString();
    final last = _lines.length - 1;
    if (last < 0) {
      _streaming = false;
      return;
    }
    setState(() {
      _streaming = false;
      if (error != null) {
        if (_convo.isNotEmpty) {
          _convo.removeLast(); // giliran yang gagal tidak ikut dikirim ulang
        }
        final shown = friendlyError(error);
        _lines[last] =
            ChatLine('error', partial.isEmpty ? shown : '$partial\n\n⚠ $shown');
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
    final t0 = _firstTokenAt, t1 = _lastTokenAt;
    if (error == null && t0 != null && t1 != null && _tokCount > 1) {
      final secs = t1.difference(t0).inMilliseconds / 1000;
      if (secs > 0.2) {
        setState(() => _statsLabel = '≈${((_tokCount - 1) / secs).toStringAsFixed(1)} token/dtk · $_tokCount token · ${secs.toStringAsFixed(1)} dtk');
      }
    }
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
      await showEngineDialog(context, current);
    } catch (e) {
      _log('ERROR', 'Pengaturan engine gagal dimuat: $e');
      toast('Pengaturan tidak bisa dimuat');
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

  Future<void> _openThemePicker() async {
    final selected = await showModalBottomSheet<NeuronThemePreset>(
      context: context,
      backgroundColor: panel,
      showDragHandle: true,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('Pilih tema NeuroN', style: TextStyle(fontWeight: FontWeight.w700)), subtitle: Text('Ganti warna aksen untuk tampilan workspace.')),
        for (final preset in NeuronThemePreset.values) ListTile(
          leading: CircleAvatar(backgroundColor: themeAccent(preset), radius: 12),
          title: Text(themeLabel(preset)),
          trailing: preset == widget.themePreset ? const Icon(Icons.check, color: blue) : null,
          onTap: () => Navigator.pop(ctx, preset),
        ),
        const SizedBox(height: 8),
      ])),
    );
    if (selected != null) widget.onThemeChanged(selected);
  }

  void _openWorkspace(String page) => setState(() {
        _section = 'Workspace';
        _workspacePage = page;
        _copilotComplaint = '';
        _copilotSample = '';
        _hubAutoStart = '';
        _editModelPath = '';
      });

  /// Buka Editor GGUF langsung pada model [path] (kosong = tampilkan daftar model).
  void _openGgufEditor(String path) => setState(() {
        _section = 'Workspace';
        _workspacePage = 'Edit model';
        _copilotComplaint = '';
        _copilotSample = '';
        _hubAutoStart = '';
        _editModelPath = path;
      });

  /// Buka Copilot dengan jawaban chat tertentu sebagai contoh masalah, lalu minta saran perbaikan konfigurasi.
  void _fixFromChat(int index) {
    if (index < 0 || index >= _lines.length) return;
    var question = '';
    for (var i = index - 1; i >= 0; i--) {
      if (_lines[i].role == 'user') {
        question = _lines[i].text;
        break;
      }
    }
    final shortQ = question.length > 160 ? '${question.substring(0, 160)}…' : question;
    setState(() {
      _copilotSample = _lines[index].text;
      _copilotComplaint = shortQ.isEmpty ? '' : 'Jawaban tidak sesuai untuk pertanyaan: "$shortQ". Perbaiki pengaturan agar jawabannya lebih baik.';
      _section = 'Workspace';
      _workspacePage = 'Copilot';
    });
  }

  bool get _needsModel => _dashboardEngine != null && _dashboardEngine!.modelPath.isEmpty;

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
            ListTile(
              leading: const Icon(Icons.table_chart_outlined, color: purple),
              title: const Text('Dataset training'),
              subtitle: const Text('Pilih, validasi, lalu siapkan dataset untuk training'),
              onTap: () => Navigator.pop(ctx, 'Latih'),
            ),
          ]),
        ),
      ),
    );
    if (target != null) _openWorkspace(target);
  }

  /// Simpan percakapan aktif ke arsip (bila ada isinya) agar bisa dibuka lagi dari Riwayat.
  Future<void> _archiveCurrent() async {
    final rows = _lines.map((l) => {'role': l.role, 'text': l.text}).toList();
    if (!rows.any((r) => r['role'] == 'user')) return;
    await ConversationStore.add(SavedConversation(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: conversationTitle(rows),
      updated: DateTime.now().millisecondsSinceEpoch,
      lines: rows,
      convo: List<Map<String, String>>.of(_convo),
    ));
  }

  Future<void> _newConversation() async {
    if (_streaming || _clearingChat) return;
    try {
      await _archiveCurrent();
    } catch (e) {
      _log('WARN', 'Percakapan tidak bisa diarsipkan: $e');
    }
    await _clearChat();
    if (mounted) toast('Percakapan baru dimulai. Yang lama ada di Riwayat.');
  }

  String _dateLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _openHistory() async {
    if (_streaming) return;
    var items = await ConversationStore.all();
    if (!mounted) return;
    final picked = await showModalBottomSheet<SavedConversation>(
      context: context,
      backgroundColor: panel,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .7),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
                child: Row(children: [
                  const Expanded(child: Text('Riwayat percakapan', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                  if (items.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        await ConversationStore.clear();
                        setSheet(() => items = []);
                      },
                      child: const Text('Hapus semua'),
                    ),
                ]),
              ),
              if (items.isEmpty)
                const Padding(padding: EdgeInsets.all(28), child: Text('Belum ada percakapan tersimpan. Percakapan lama muncul di sini saat Anda memulai percakapan baru.', textAlign: TextAlign.center, style: TextStyle(color: muted, fontSize: 12)))
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final c = items[i];
                      return ListTile(
                        title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                        subtitle: Text('${_dateLabel(c.updated)} · ${c.lines.where((l) => l['role'] == 'user').length} pesan', style: const TextStyle(fontSize: 11, color: muted)),
                        trailing: IconButton(
                          tooltip: 'Hapus',
                          icon: const Icon(Icons.delete_outline, size: 19, color: muted),
                          onPressed: () async {
                            await ConversationStore.remove(c.id);
                            setSheet(() => items = items.where((e) => e.id != c.id).toList());
                          },
                        ),
                        onTap: () => Navigator.pop(ctx, c),
                      );
                    },
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await _archiveCurrent();
      await ConversationStore.remove(picked.id);
    } catch (e) {
      _log('WARN', 'Arsip percakapan gagal: $e');
    }
    setState(() {
      _lines
        ..clear()
        ..addAll(picked.lines.map((r) => ChatLine(r['role'] ?? 'assistant', r['text'] ?? '')));
      _convo
        ..clear()
        ..addAll(picked.convo);
      _statsLabel = null;
    });
    unawaited(_persistChat());
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
        _chatNotices.clear();
        _clearingChat = false;
      });
      _log('INFO', 'Percakapan aktif dibersihkan');
    } catch (e) {
      if (mounted) setState(() => _clearingChat = false);
      _log('ERROR', 'Gagal membersihkan percakapan: $e');
      toast('Percakapan baru tidak berhasil dimulai');
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
      key: ValueKey('${_workspacePage}_${_copilotSample.hashCode}_${_hubAutoStart}_$_editModelPath'),
      hubAutoStartRepo: _hubAutoStart,
      initialModelPath: _editModelPath,
      onEditModel: _openGgufEditor,
      onGoSection: _goTo,
      onGuardrailChanged: _refreshEngine,
      page: _workspacePage ?? '',
      initialComplaint: _copilotComplaint,
      initialSample: _copilotSample,
      onOpenChat: () {
        setState(() => _workspacePage = null);
        _refreshEngine();
        _goTo('Chat');
      },
      onOpenPage: _openWorkspace,
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
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(begin: const Offset(.025, 0), end: Offset.zero).animate(animation),
                  child: child,
                ),
              ),
              child: KeyedSubtree(
                key: ValueKey(_pageIndex),
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
              tooltip: 'Riwayat percakapan',
              onPressed: _streaming ? null : _openHistory,
              icon: const Icon(Icons.history, size: 19),
            ),
            IconButton(
              tooltip: 'Percakapan baru',
              onPressed: _streaming || _clearingChat ? null : _newConversation,
              icon: const Icon(Icons.add_comment_outlined, size: 19),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 5),
          child: Row(children: [
            const Icon(Icons.swap_horiz, size: 16, color: muted),
            const SizedBox(width: 6),
            const Text('Model Chat', style: TextStyle(fontSize: 11, color: muted)),
            const SizedBox(width: 8),
            Expanded(
              child: ModelSelector(
                models: _localModels,
                busy: _modelBusy,
                locked: _streaming,
                onSelect: _selectChatModel,
                onRefresh: _refreshLocalModels,
              ),
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
            onFix: _streaming ? null : _fixFromChat,
            statsLabel: _statsLabel,
            notices: _chatNotices,
            flowStep: _needsModel ? 0 : 3,
            suggestions: _needsModel
                ? const {}
                : const {
                    'Ringkas teks': 'Ringkas teks berikut dalam 5 poin:\n',
                    'Jelaskan sederhana': 'Jelaskan dengan bahasa sederhana: ',
                    'Bantu kode': 'Bantu saya menulis dan memperbaiki kode ini:\n',
                  },
            onEdit: _streaming ? null : _editMessage,
            onRegenerate: _streaming ? null : _regenerate,
            emptyAction: _needsModel
                ? FilledButton.icon(
                    onPressed: () => _openWorkspace('Model Hub'),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Unduh model di Model Hub'),
                    style: FilledButton.styleFrom(backgroundColor: blue),
                  )
                : null,
            hint: _needsModel
                ? 'Belum ada model aktif. Unduh model GGUF dari Model Hub atau impor lewat menu Import.'
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
        onEditModel: () => _openGgufEditor(_dashboardEngine?.modelPath ?? ''),
      );

  Widget _importPage() => ImportCenterPage(
        onModelHub: () => _openWorkspace('Model Hub'),
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
        onTutorial: () => showNeuroNTutorial(context),
        onTheme: _openThemePicker,
        onOpenTool: _openWorkspace,
        onAbout: () => showAboutNeuroN(context),
      );

  Widget _workspaceEditorPage() {
    if (_workspacePage != null) return _workspaceStatus();
    return Column(children: [
      _editorHeader(),
      _toolbar(),
      _tabStrip(),
      if (_findOpen && _mode == 'Kode') _findBar(),
      Expanded(child: _mainArea()),
      if (_problemsOpen && _active != null)
        ProblemsPanel(
          problems: analyze(_active, _text),
          onJump: _jumpTo,
          onClose: () => setState(() => _problemsOpen = false),
        ),
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
                      color: _engineStatus.startsWith('Lokal ·')
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

  /// Tab berkas yang sedang terbuka: titik kuning = belum disimpan, x = tutup.
  Widget _tabStrip() {
    if (_hist.isEmpty) return const SizedBox.shrink();
    return Container(
      height: 34,
      color: ink,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final path in _hist.keys.toList())
            InkWell(
              onTap: path == _active ? null : () => _open(path),
              child: Container(
                padding: const EdgeInsets.only(left: 10, right: 2),
                decoration: BoxDecoration(
                  color: path == _active ? panel : ink,
                  border: Border(
                    top: BorderSide(color: path == _active ? blue : Colors.transparent, width: 2),
                    right: const BorderSide(color: line),
                  ),
                ),
                child: Row(children: [
                  Text(path.split('/').last,
                      style: TextStyle(fontSize: 11, color: path == _active ? Colors.white : muted)),
                  const SizedBox(width: 4),
                  if (_isDirty(path))
                    const Icon(Icons.circle, size: 8, color: amber)
                  else
                    const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Tutup tab',
                    visualDensity: VisualDensity.compact,
                    iconSize: 14,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                    icon: const Icon(Icons.close),
                    onPressed: () => _closeTab(path),
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _closeTab(String path) async {
    if (_isDirty(path)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Tutup tanpa menyimpan?'),
          content: Text('${path.split('/').last} punya perubahan yang belum disimpan.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Tutup')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final keys = _hist.keys.toList();
    final i = keys.indexOf(path);
    _hist.remove(path);
    _saved.remove(path);
    _drafts.remove(path);
    if (path == _active) {
      final rest = _hist.keys.toList();
      if (rest.isEmpty) {
        setState(() => _active = null);
        _editor.value = TextEditingValue.empty;
      } else {
        await _open(rest[i.clamp(0, rest.length - 1)]);
      }
    } else {
      setState(() {});
    }
    _persistTabs();
  }

  /// Lompat kursor ke baris:kolom (dari panel Masalah).
  void _jumpTo(Problem p) {
    final off = offsetOf(_editor.text, p.line, p.column);
    _editor.selection = TextSelection.collapsed(offset: off);
  }

  void _openPalette() {
    final editing = _mode == 'Kode' && _active != null;
    showCommandPalette(context, [
      PaletteCommand('Simpan', Icons.save_outlined, _save, hint: 'Simpan berkas aktif', enabled: _dirtyActive),
      PaletteCommand('Rapikan JSON', Icons.auto_fix_high_rounded, _format, enabled: editing && _activeIsJson),
      PaletteCommand('Cari dan ganti', Icons.search_rounded, () => setState(() => _findOpen = !_findOpen), enabled: editing),
      PaletteCommand('Isi dari model lokal', Icons.memory_outlined, _fillFromLocalModel, enabled: canFillFromModel(_active)),
      PaletteCommand('Tampilkan/sembunyikan Masalah', Icons.error_outline, () => setState(() => _problemsOpen = !_problemsOpen), enabled: _active != null),
      PaletteCommand('Buka file…', Icons.folder_copy_outlined, _showWorkspaceFiles),
      PaletteCommand('Undo', Icons.undo_rounded, _undo, enabled: _h?.canUndo ?? false),
      PaletteCommand('Redo', Icons.redo_rounded, _redo, enabled: _h?.canRedo ?? false),
      PaletteCommand('Edit model', Icons.edit_note_outlined, () => _openWorkspace('Edit model'), hint: 'Info, metadata, privasi, LoRA'),
      PaletteCommand('Ganti tema', Icons.palette_outlined, _openThemePicker),
    ]);
  }

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
          _tool(Icons.terminal_rounded, 'Command palette', _openPalette),
          _tool(Icons.memory_outlined, 'Isi dari model lokal',
              canFillFromModel(_active) ? _fillFromLocalModel : null),
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
    final editor = CodeEditor(
        key: ValueKey(_active),
        controller: _editor,
        onChanged: _onEdit,
        language: languageForPath(_active),
        path: _active);
    final note = _inertNote(_active);
    if (note == null) return editor;
    return Column(children: [
      Container(
        width: double.infinity,
        color: const Color(0xFF3A2F12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(note, style: const TextStyle(color: amber, fontSize: 11, height: 1.35)),
      ),
      Expanded(child: editor),
    ]);
  }

  /// Berkas konfigurasi yang tidak mengubah model yang berjalan. Katakan terus terang agar tidak dikira edit model.
  static String? _inertNote(String? path) => switch (path) {
        'model/config.json' =>
          'Berkas ini hanya dibaca Copilot untuk pemeriksaan konsistensi. Engine tidak memakainya, jadi mengubahnya tidak mengubah model. Untuk mengubah model, buka Lainnya → Edit model.',
        'tokenizer/vocab.json' =>
          'Vocab sebenarnya dibaca dari dalam berkas GGUF. Berkas ini hanya dipakai pemeriksaan Copilot dan tidak mengubah model. Untuk mengubah model, buka Lainnya → Edit model.',
        'tokenizer/tokenizer.json' =>
          'Hanya token khusus EOS di sini yang dipakai sebagai kata berhenti. Tokenizer dan vocab model dibaca dari berkas GGUF. Untuk mengubahnya, buka Lainnya → Edit model.',
        'model/ops.json' =>
          'Hanya konfigurasi operasi model. Eksekusinya lewat server HTTPS di halaman Latih, bukan di perangkat.',
        _ => null,
      };

  Widget _statusBar() {
    final valid = _activeIsJson ? _jsonValid(_text) : null;
    final probs = _active == null ? const <Problem>[] : analyze(_active, _text);
    final errs = probs.where((p) => p.error).length;
    final warns = probs.length - errs;
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
        const SizedBox(width: 10),
        if (_active != null)
          InkWell(
            onTap: () => setState(() => _problemsOpen = !_problemsOpen),
            child: Text('⊗ $errs  ⚠ $warns',
                style: TextStyle(fontSize: 10, color: errs > 0 ? Colors.redAccent : (warns > 0 ? amber : Colors.white70))),
          ),
        const Spacer(),
        if (_active != null)
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _editor,
            builder: (_, v, __) {
              final off = v.selection.isValid ? v.selection.baseOffset.clamp(0, v.text.length) : 0;
              final (l, c) = lineCol(v.text, off);
              return Text('Ln $l, Kol $c  ·  ',
                  style: const TextStyle(fontSize: 9, color: Colors.white70));
            },
          ),
        Text('${_text.split('\n').length} baris',
            style: const TextStyle(fontSize: 9, color: Colors.white70)),
      ]),
    );
  }
}
