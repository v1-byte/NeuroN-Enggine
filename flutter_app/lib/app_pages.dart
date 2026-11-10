import 'package:flutter/material.dart';

import 'bridge.dart';
import 'theme.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.engineStatus,
    required this.serverRunning,
    required this.ragEnabled,
    required this.documentCount,
    required this.chunkCount,
    required this.recentLogs,
    required this.onChat,
    required this.onImport,
    required this.onLibrary,
    required this.onSettings,
    required this.onWorkspace,
    required this.onActivity,
  });

  final String engineStatus;
  final bool serverRunning;
  final bool ragEnabled;
  final int documentCount;
  final int chunkCount;
  final List<String> recentLogs;
  final VoidCallback onChat;
  final VoidCallback onImport;
  final VoidCallback onLibrary;
  final VoidCallback onSettings;
  final VoidCallback onWorkspace;
  final VoidCallback onActivity;

  bool get _engineConfigured =>
      engineStatus.startsWith('API ·') ||
      (engineStatus.startsWith('Lokal ·') &&
          !engineStatus.contains('native belum tersedia'));

  @override
  Widget build(BuildContext context) {
    final ready = _engineConfigured;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
      children: [
        const Text('AI WORKSPACE',
            style: TextStyle(
                color: blue,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5)),
        const SizedBox(height: 7),
        const Text('Selamat datang',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        const Text('Siapkan engine, kelola file, lalu mulai bekerja.',
            style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 18),
        _heroCard(ready),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: _summaryCard(
              icon: Icons.memory_outlined,
              title: 'Engine aktif',
              value: engineStatus,
              tint: ready ? green : Colors.orangeAccent,
              onTap: onSettings,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _summaryCard(
              icon: Icons.auto_awesome_mosaic_outlined,
              title: 'Knowledge',
              value: '$documentCount dokumen · $chunkCount chunk · RAG ${ragEnabled ? 'aktif' : 'nonaktif'}',
              tint: purple,
              onTap: onLibrary,
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: _summaryCard(
              icon: Icons.dns_outlined,
              title: 'Server lokal',
              value: serverRunning ? 'Berjalan' : 'Berhenti',
              tint: serverRunning ? green : muted,
              onTap: onSettings,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _summaryCard(
              icon: Icons.folder_copy_outlined,
              title: 'Ruang kerja',
              value: 'Editor & konfigurasi',
              tint: blue,
              onTap: onWorkspace,
            ),
          ),
        ]),
        const SizedBox(height: 20),
        Row(children: [
          const Expanded(
            child: Text('Aktivitas terbaru',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          TextButton(onPressed: onActivity, child: const Text('Lihat semua')),
        ]),
        if (recentLogs.isEmpty)
          _emptyActivity()
        else
          ...recentLogs.take(3).map(_activityRow),
      ],
    );
  }

  Widget _heroCard(bool ready) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF203D68), Color(0xFF191D30), Color(0xFF191D30)],
          ),
          border: Border.all(color: const Color(0xFF344A70)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                  color: const Color(0xFF31558B),
                  borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.hub_outlined, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Status engine',
                    style: TextStyle(color: muted, fontSize: 10)),
                Text(ready ? 'Konfigurasi tersedia' : 'Perlu konfigurasi',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ]),
            ),
            Icon(Icons.circle, size: 9, color: ready ? green : Colors.orangeAccent),
          ]),
          const SizedBox(height: 10),
          Text(engineStatus,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
          const SizedBox(height: 16),
          Wrap(spacing: 9, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: ready ? onChat : onSettings,
              icon: Icon(ready ? Icons.chat_bubble_outline : Icons.tune),
              label: Text(ready ? 'Mulai chat' : 'Atur engine'),
              style: FilledButton.styleFrom(
                  backgroundColor: blue,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 42)),
            ),
            OutlinedButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('Import file'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF53617B)),
                  minimumSize: const Size(0, 42)),
            ),
          ]),
        ]),
      );

  Widget _summaryCard({
    required IconData icon,
    required String title,
    required String value,
    required Color tint,
    required VoidCallback onTap,
  }) => Material(
        color: panel,
        borderRadius: BorderRadius.circular(15),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(15),
          child: Container(
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: line)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: tint, size: 19),
              const SizedBox(height: 9),
              Text(title, style: const TextStyle(color: muted, fontSize: 10)),
              const SizedBox(height: 3),
              Text(value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );

  Widget _emptyActivity() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: line)),
        child: const Row(children: [
          Icon(Icons.inbox_outlined, color: muted, size: 19),
          SizedBox(width: 10),
          Expanded(
              child: Text('Belum ada aktivitas. Proses import dan chat akan muncul di sini.',
                  style: TextStyle(color: muted, fontSize: 11))),
        ]),
      );

  Widget _activityRow(String text) => Container(
        margin: const EdgeInsets.only(bottom: 7),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: line)),
        child: Row(children: [
          const Icon(Icons.bolt_outlined, color: blue, size: 17),
          const SizedBox(width: 9),
          Expanded(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Colors.white70))),
        ]),
      );
}

class ImportCenterPage extends StatelessWidget {
  const ImportCenterPage({
    super.key,
    required this.onDevice,
    required this.onHuggingFace,
    required this.onLibrary,
  });

  final VoidCallback onDevice;
  final VoidCallback onHuggingFace;
  final VoidCallback onLibrary;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
        children: [
          const Text('Import Center',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Pilih sumber terlebih dahulu, lalu tentukan tujuan file.',
              style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 18),
          _sourceCard(
            icon: Icons.phone_android_outlined,
            title: 'Perangkat ini',
            subtitle: 'Pilih model GGUF atau dokumen dari penyimpanan Android.',
            enabled: true,
            onTap: onDevice,
            action: 'Pilih tujuan',
          ),
          _sourceCard(
            icon: Icons.cloud_download_outlined,
            title: 'Hugging Face',
            subtitle: 'Cari repository GGUF dan unduh model ke perangkat.',
            enabled: true,
            onTap: onHuggingFace,
            action: 'Cari model',
          ),
          _sourceCard(
            icon: Icons.folder_copy_outlined,
            title: 'Folder NeuroN',
            subtitle: 'Lihat model dan dokumen yang sudah dikelola aplikasi.',
            enabled: true,
            onTap: onLibrary,
            action: 'Buka Library',
          ),
          const SizedBox(height: 8),
          const Text('Sumber lain',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _sourceCard(
            icon: Icons.link_outlined,
            title: 'URL / HTTP',
            subtitle: 'Pengunduhan langsung dari URL belum tersedia di build ini.',
            enabled: false,
          ),
          _sourceCard(
            icon: Icons.cloud_outlined,
            title: 'Cloud storage',
            subtitle: 'Google Drive, Dropbox, dan OneDrive belum terhubung.',
            enabled: false,
          ),
          _sourceCard(
            icon: Icons.devices_outlined,
            title: 'Server lokal',
            subtitle: 'Pairing dan transfer file melalui LAN belum tersedia.',
            enabled: false,
          ),
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: const Color(0xFF382A1C),
                borderRadius: BorderRadius.circular(12)),
            child: const Text(
                'Import model dan dokumen memakai penyimpanan privat aplikasi. Sebelum mengunduh file besar, pastikan ruang penyimpanan cukup.',
                style: TextStyle(fontSize: 10, color: Colors.white70, height: 1.4)),
          ),
        ],
      );

  Widget _sourceCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool enabled,
    VoidCallback? onTap,
    String? action,
  }) => Opacity(
        opacity: enabled ? 1 : .62,
        child: Card(
          margin: const EdgeInsets.only(bottom: 9),
          color: panel,
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(13),
              child: Row(children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                      color: const Color(0xFF252D43),
                      borderRadius: BorderRadius.circular(12)),
                  child: Icon(icon, color: enabled ? blue : muted, size: 20),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(subtitle,
                        style: const TextStyle(color: muted, fontSize: 10, height: 1.3)),
                  ]),
                ),
                if (action != null)
                  const Icon(Icons.chevron_right, color: muted, size: 19)
                else
                  const Text('Segera', style: TextStyle(color: muted, fontSize: 9)),
              ]),
            ),
          ),
        ),
      );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.engine,
    required this.knowledgeFiles,
    required this.chunkCount,
    required this.onImport,
    required this.onModelSettings,
    required this.onKnowledgeSettings,
  });

  final EngineSettings? engine;
  final List<String> knowledgeFiles;
  final int chunkCount;
  final VoidCallback onImport;
  final VoidCallback onModelSettings;
  final VoidCallback onKnowledgeSettings;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _filter = 'Semua';

  @override
  Widget build(BuildContext context) {
    final model = widget.engine?.modelPath ?? '';
    final localModel = model.isNotEmpty ? model.split('/').last : null;
    final filters = const ['Semua', 'Model', 'Knowledge', 'Dataset', 'Adapter'];
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
      children: [
        Row(children: [
          const Expanded(
              child: Text('Library',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700))),
          IconButton.filledTonal(
              tooltip: 'Import file',
              onPressed: widget.onImport,
              icon: const Icon(Icons.add)),
        ]),
        const SizedBox(height: 6),
        const Text('Kelola model dan sumber knowledge di perangkat.',
            style: TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 15),
        Wrap(
          spacing: 7,
          runSpacing: 6,
          children: filters
              .map((f) => ChoiceChip(
                    label: Text(f),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ))
              .toList(),
        ),
        const SizedBox(height: 14),
        if (_filter == 'Semua' || _filter == 'Model') ...[
          _sectionLabel('MODEL'),
          if (localModel == null)
            _emptyCard(
                Icons.memory_outlined,
                'Belum ada model lokal',
                'Pilih file GGUF atau cari model di Hugging Face.',
                widget.onImport)
          else
            _fileCard(
              icon: Icons.memory_outlined,
              name: localModel,
              detail: 'Model lokal · ${widget.engine?.mode == 'LOCAL' ? 'terpilih' : 'tersimpan'}',
              status: widget.engine?.mode == 'LOCAL' ? 'Aktif' : 'Tersimpan',
              onTap: widget.onModelSettings,
            ),
          const SizedBox(height: 14),
        ],
        if (_filter == 'Semua' || _filter == 'Knowledge') ...[
          _sectionLabel('KNOWLEDGE'),
          if (widget.knowledgeFiles.isEmpty)
            _emptyCard(
                Icons.menu_book_outlined,
                'Belum ada dokumen knowledge',
                'Tambahkan dokumen untuk menyiapkan sumber RAG.',
                widget.onKnowledgeSettings)
          else ...[
            _infoStrip('${widget.knowledgeFiles.length} dokumen · ${widget.chunkCount} chunk terindeks'),
            const SizedBox(height: 8),
            ...widget.knowledgeFiles.take(40).map((file) => _fileCard(
                  icon: Icons.description_outlined,
                  name: file.split('/').last,
                  detail: 'Knowledge · sumber RAG',
                  status: 'Tersimpan',
                  onTap: widget.onKnowledgeSettings,
                )),
          ],
          const SizedBox(height: 14),
        ],
        if (_filter == 'Semua' || _filter == 'Dataset') ...[
          _sectionLabel('DATASET'),
          _emptyCard(Icons.table_chart_outlined, 'Belum ada dataset',
              'Validasi dan penyimpanan dataset belum dihubungkan ke UI.', null),
          const SizedBox(height: 14),
        ],
        if (_filter == 'Semua' || _filter == 'Adapter') ...[
          _sectionLabel('ADAPTER'),
          _emptyCard(Icons.extension_outlined, 'Belum ada adapter',
              'Workflow training dan pengelolaan adapter belum tersedia.', null),
        ],
      ],
    );
  }

  Widget _sectionLabel(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(label,
            style: const TextStyle(
                color: muted,
                fontSize: 9,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2)),
      );

  Widget _emptyCard(
          IconData icon, String title, String detail, VoidCallback? action) =>
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: line)),
        child: Row(children: [
          Icon(icon, color: muted, size: 21),
          const SizedBox(width: 11),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(detail,
                style: const TextStyle(color: muted, fontSize: 10, height: 1.35)),
            if (action != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                  onPressed: action,
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text('Tambah'),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero)),
            ],
          ])),
        ]),
      );

  Widget _fileCard({
    required IconData icon,
    required String name,
    required String detail,
    required String status,
    required VoidCallback onTap,
  }) => Card(
        margin: const EdgeInsets.only(bottom: 7),
        color: panel,
        child: ListTile(
          onTap: onTap,
          leading: Icon(icon, color: blue),
          title: Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          subtitle: Text(detail,
              style: const TextStyle(color: muted, fontSize: 10)),
          trailing: Text(status,
              style: const TextStyle(color: green, fontSize: 9)),
        ),
      );

  Widget _infoStrip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
            color: const Color(0xFF1C2C42),
            borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: const TextStyle(color: blue, fontSize: 10)),
      );
}

class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key, required this.logs});
  final List<String> logs;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
        children: [
          const Text('Activity',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Riwayat operasi engine, chat, dan file.',
              style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 15),
          if (logs.isEmpty)
            const Card(
                color: panel,
                child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('Belum ada aktivitas.',
                        style: TextStyle(color: muted, fontSize: 12))))
          else
            ...logs.reversed.map((entry) => Card(
                  color: panel,
                  margin: const EdgeInsets.only(bottom: 7),
                  child: Padding(
                    padding: const EdgeInsets.all(11),
                    child: SelectableText(entry,
                        style: TextStyle(
                            color: entry.contains(' ERROR ') ? errorRed : Colors.white70,
                            fontFamily: 'monospace',
                            fontSize: 10)),
                  ),
                )),
          const SizedBox(height: 8),
          const Text(
              'Catatan: progress unduhan Hugging Face tampil pada layar Hugging Face. Riwayat pekerjaan terpusat belum tersedia.',
              style: TextStyle(color: muted, fontSize: 10, height: 1.4)),
        ],
      );
}

class MorePage extends StatelessWidget {
  const MorePage({
    super.key,
    required this.onWorkspace,
    required this.onActivity,
    required this.onSettings,
    required this.onFeatures,
    required this.onOpenTool,
  });

  final VoidCallback onWorkspace;
  final VoidCallback onActivity;
  final VoidCallback onSettings;
  final VoidCallback onFeatures;
  final ValueChanged<String> onOpenTool;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
        children: [
          const Text('Lainnya',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Workspace, operasi, dan pengaturan lanjutan.',
              style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 15),
          _group('WORKSPACE', [
            _item(Icons.code_outlined, 'Editor project',
                'File konfigurasi dan parameter chat', onWorkspace),
            _item(Icons.history_outlined, 'Activity',
                'Riwayat aktivitas dan pesan diagnostik', onActivity),
          ]),
          const SizedBox(height: 12),
          _group('TOOLS', [
            _item(Icons.phone_android_outlined, 'Model lokal',
                'Pilih file GGUF dari perangkat', () => onOpenTool('Model lokal')),
            _item(Icons.cloud_download_outlined, 'Hugging Face',
                'Cari dan unduh model GGUF', () => onOpenTool('Hugging Face')),
            _item(Icons.menu_book_outlined, 'Knowledge / RAG',
                'Dokumen dan indeks knowledge', () => onOpenTool('Data & RAG')),
            _item(Icons.dns_outlined, 'Server lokal',
                'OpenAI-compatible API pada perangkat', () => onOpenTool('Server')),
            _item(Icons.auto_awesome_outlined, 'Copilot',
                'Saran patch konfigurasi', () => onOpenTool('Copilot')),
            _item(Icons.school_outlined, 'Training',
                'Eksperimental; alur Flutter belum tersedia', () => onOpenTool('Latih')),
            _item(Icons.memory_outlined, 'Hardware',
                'Pengaturan engine lanjutan', () => onOpenTool('Hardware')),
          ]),
          const SizedBox(height: 12),
          _group('PREFERENSI', [
            _item(Icons.tune_outlined, 'Fitur & guardrails',
                'Tools dan aturan keselamatan', onFeatures),
            _item(Icons.settings_outlined, 'Pengaturan engine',
                'Base URL, model, dan API key', onSettings),
          ]),
        ],
      );

  Widget _group(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 7),
            child: Text(title,
                style: const TextStyle(
                    color: muted,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2)),
          ),
          Container(
            decoration: BoxDecoration(
                color: panel,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: line)),
            child: Column(children: children),
          ),
        ],
      );

  Widget _item(IconData icon, String title, String detail, VoidCallback onTap) =>
      ListTile(
        onTap: onTap,
        leading: Icon(icon, color: blue, size: 20),
        title: Text(title,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        subtitle: Text(detail,
            style: const TextStyle(color: muted, fontSize: 10)),
        trailing: const Icon(Icons.chevron_right, color: muted, size: 18),
        dense: true,
      );
}
