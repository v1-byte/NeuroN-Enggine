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
