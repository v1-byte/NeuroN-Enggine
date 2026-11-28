import 'package:flutter/material.dart';

import 'theme.dart';

/// Selector model yang dipakai langsung dari halaman Chat.
/// Data model berasal dari Bridge.localModels().
class ModelSelector extends StatelessWidget {
  const ModelSelector({
    super.key,
    required this.models,
    required this.busy,
    this.locked = false,
    required this.onSelect,
    this.onRefresh,
  });

  final List<Map<String, dynamic>> models;
  final bool busy;
  final bool locked;
  final ValueChanged<String> onSelect;
  final VoidCallback? onRefresh;

  static String modelName(Map<String, dynamic> model) =>
      '${model['name'] ?? 'Model tanpa nama'}';

  static String sizeLabel(dynamic value) {
    final bytes = value is num ? value.toDouble() : 0;
    if (bytes <= 0) return 'Ukuran tidak diketahui';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final active = models.where((m) => m['active'] == true).toList();
    final activeName = active.isEmpty ? 'Belum ada model aktif' : modelName(active.first);
    return OutlinedButton.icon(
      onPressed: busy || locked ? null : () => _openSheet(context),
      icon: busy
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.memory_outlined, size: 17),
      label: Flexible(
        child: Text(
          busy ? 'Menyiapkan model…' : (locked ? 'Jawaban sedang berjalan…' : activeName),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10),
        ),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: active.isEmpty ? amber : blue,
        side: BorderSide(color: active.isEmpty ? amber : blue),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        minimumSize: const Size(0, 34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
    );
  }

  Future<void> _openSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Pilih model untuk Chat', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                models.length < 2
                    ? 'Model aktif akan digunakan saat Anda mengirim pesan.'
                    : 'Pilih satu model. Model baru dimuat sebelum pesan berikutnya dikirim.',
                style: const TextStyle(color: muted, fontSize: 11),
              ),
              const SizedBox(height: 10),
              if (models.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(18),
                  child: Center(child: Text('Belum ada model GGUF terpasang.', style: TextStyle(color: muted))),
                )
              else
                ...models.map((model) {
                  final path = '${model['path'] ?? ''}';
                  final isActive = model['active'] == true;
                  return Card(
                    color: isActive ? const Color(0x223D8BFF) : panel2,
                    child: ListTile(
                      dense: true,
                      leading: Icon(isActive ? Icons.check_circle : Icons.radio_button_unchecked,
                          color: isActive ? green : muted),
                      title: Text(modelName(model), maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${sizeLabel(model['size'])}${isActive ? ' · Aktif untuk Chat' : ' · Belum dipilih'}',
                          style: const TextStyle(fontSize: 10, color: muted)),
                      trailing: isActive
                          ? const Chip(label: Text('Dipakai', style: TextStyle(fontSize: 10)), visualDensity: VisualDensity.compact)
                          : FilledButton.tonal(
                              onPressed: busy || path.isEmpty
                                  ? null
                                  : () {
                                      Navigator.pop(sheetContext);
                                      onSelect(path);
                                    },
                              child: const Text('Pilih', style: TextStyle(fontSize: 10)),
                            ),
                      onTap: isActive || busy || path.isEmpty
                          ? null
                          : () {
                              Navigator.pop(sheetContext);
                              onSelect(path);
                            },
                    ),
                  );
                }),
              if (onRefresh != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: busy ? null : onRefresh,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Muat ulang daftar'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
