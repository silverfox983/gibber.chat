import 'dart:io';
import 'dart:async';
import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:file_picker/file_picker.dart';


class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  List<File> _recordings = [];
  bool _isLoading = true;
  bool _isExporting = false;
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _playingFilePath;
  Duration _playbackPos = Duration.zero;
  Duration _playbackDur = Duration.zero;
  final Set<String> _selected = {};
  bool _selectionMode = false;

  // Subscriptions
  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _completeSub;

  @override
  void initState() {
    super.initState();
    _loadRecordings();
    _posSub = _audioPlayer.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _playbackPos = pos);
    });
    _durSub = _audioPlayer.onDurationChanged.listen((dur) {
      if (mounted) setState(() => _playbackDur = dur);
    });
    _completeSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _playingFilePath = null; _playbackPos = Duration.zero; });
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _completeSub?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadRecordings() async {
    setState(() => _isLoading = true);
    try {
      if (kIsWeb) { if (mounted) setState(() => _isLoading = false); return; }
      final docsDir = await getApplicationDocumentsDirectory();
      final exportDir = Directory('${docsDir.path}/GibberExport/Calls');

      if (await exportDir.exists()) {
        final List<FileSystemEntity> entities = await exportDir.list().toList();
        final List<File> files = entities
            .whereType<File>()
            .where((f) => f.path.endsWith('.mp4') || f.path.endsWith('.aac') || f.path.endsWith('.m4a') || f.path.endsWith('.wav'))
            .toList();

        files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
        if (mounted) setState(() => _recordings = files);
      }
    } catch (e) {
      debugPrint('Error loading recordings: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteRecording(File file) async {
    try {
      if (_playingFilePath == file.path) {
        await _audioPlayer.stop();
        setState(() { _playingFilePath = null; _playbackPos = Duration.zero; });
      }
      await file.delete();
      _selected.remove(file.path);
      _loadRecordings();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recording deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error deleting: $e')));
      }
    }
  }

  Future<void> _deleteSelected() async {
    final count = _selected.length;
    final toDelete = _recordings.where((f) => _selected.contains(f.path)).toList();
    for (final f in toDelete) {
      try {
        if (_playingFilePath == f.path) {
          await _audioPlayer.stop();
          setState(() { _playingFilePath = null; _playbackPos = Duration.zero; });
        }
        await f.delete();
      } catch (_) {}
    }
    _selected.clear();
    setState(() => _selectionMode = false);
    _loadRecordings();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$count recording(s) deleted')));
    }
  }

  // ── Single file: share via system sheet ──────────────────────────────────
  Future<void> _shareRecording(File file) async {
    await Share.shareXFiles(
      [XFile(file.path, mimeType: _mimeFor(file.path))],
      subject: 'Call Recording – ${_displayName(file)}',
    );
  }

  // ── Single file: copy to user-picked folder ──────────────────────────────
  Future<void> _exportToFolder(File file) async {
    final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose export folder');
    if (dir == null) return;
    try {
      final dest = File('$dir/${file.path.split(RegExp(r'[/\\]')).last}');
      await file.copy(dest.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exported to $dir'),
            action: SnackBarAction(label: 'OPEN', onPressed: () => OpenFilex.open(dest.path)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  // ── Batch: zip selected (or all) and share/save ──────────────────────────
  Future<void> _exportBatch({bool shareMode = false}) async {
    final targets = _selectionMode && _selected.isNotEmpty
        ? _recordings.where((f) => _selected.contains(f.path)).toList()
        : _recordings;

    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No recordings to export')));
      return;
    }

    setState(() => _isExporting = true);
    try {
      if (kIsWeb) { setState(() => _isExporting = false); return; }
      final tmp = await getTemporaryDirectory();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final zipPath = '${tmp.path}/gibber_recordings_$stamp.zip';

      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      for (final f in targets) {
        encoder.addFile(f);
      }
      encoder.close();

      final zipFile = File(zipPath);

      if (shareMode) {
        await Share.shareXFiles(
          [XFile(zipPath, mimeType: 'application/zip')],
          subject: 'Gibber Call Recordings',
          text: '${targets.length} call recording(s) exported from Gibber',
        );
      } else {
        final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose export folder');
        if (dir == null) {
          zipFile.deleteSync();
          return;
        }
        final dest = File('$dir/gibber_recordings_$stamp.zip');
        await zipFile.copy(dest.path);
        zipFile.deleteSync();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Exported ${targets.length} recording(s) to $dir'),
              action: SnackBarAction(label: 'OPEN', onPressed: () => OpenFilex.open(dest.path)),
            ),
          );
        }
      }

      // Exit selection mode after export
      if (mounted) setState(() { _selectionMode = false; _selected.clear(); });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _togglePlay(String path) async {
    if (_playingFilePath == path) {
      await _audioPlayer.stop();
      setState(() { _playingFilePath = null; _playbackPos = Duration.zero; });
    } else {
      await _audioPlayer.stop();
      setState(() { _playingFilePath = path; _playbackPos = Duration.zero; });
      await _audioPlayer.play(DeviceFileSource(path));
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  String _displayName(File file) {
    final filename = file.path.split(RegExp(r'[/\\]')).last;
    if (filename.startsWith('call_') && (filename.endsWith('.mp4') || filename.endsWith('.aac') || filename.endsWith('.m4a'))) {
      final parts = filename.split('_');
      if (parts.length >= 3) return 'Call with ${parts[1]}';
    }
    return filename;
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDate(DateTime date) => DateFormat('MMM d, yyyy – h:mm a').format(date);

  String _formatDuration(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  String _mimeFor(String path) {
    if (path.endsWith('.mp4')) return 'video/mp4';
    if (path.endsWith('.aac')) return 'audio/aac';
    if (path.endsWith('.m4a')) return 'audio/mp4';
    if (path.endsWith('.wav')) return 'audio/wav';
    return 'application/octet-stream';
  }

  bool _isAudio(String path) =>
      path.endsWith('.aac') || path.endsWith('.m4a') || path.endsWith('.wav');

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      final theme = Theme.of(context);
      return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(title: const Text('Recordings')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_off_rounded, size: 80, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
              const SizedBox(height: 16),
              Text('Not available on web', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Call recordings are available on mobile and desktop.', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13)),
            ],
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    final hasSelection = _selectionMode && _selected.isNotEmpty;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: _selectionMode
            ? Text('${_selected.length} selected',
                style: const TextStyle(fontWeight: FontWeight.w900))
            : const Text('Call Recordings',
                style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(() { _selectionMode = false; _selected.clear(); }),
              )
            : null,
        actions: _selectionMode
            ? [
                if (hasSelection) ...[
                  IconButton(
                    tooltip: 'Share selected as ZIP',
                    icon: const Icon(Icons.share_rounded),
                    onPressed: _isExporting ? null : () => _exportBatch(shareMode: true),
                  ),
                  IconButton(
                    tooltip: 'Export selected to folder',
                    icon: const Icon(Icons.drive_folder_upload_rounded),
                    onPressed: _isExporting ? null : () => _exportBatch(shareMode: false),
                  ),
                  IconButton(
                    tooltip: 'Delete selected',
                    icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
                    onPressed: () => _confirmDeleteSelected(context),
                  ),
                ],
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_selected.length == _recordings.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(_recordings.map((f) => f.path));
                      }
                    });
                  },
                  child: Text(_selected.length == _recordings.length ? 'None' : 'All'),
                ),
              ]
            : [
                if (_recordings.isNotEmpty) ...[
                  IconButton(
                    tooltip: 'Select recordings',
                    icon: const Icon(Icons.checklist_rounded),
                    onPressed: () => setState(() => _selectionMode = true),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Export options',
                    icon: const Icon(Icons.file_upload_outlined),
                    onSelected: (v) {
                      if (v == 'share_all') _exportBatch(shareMode: true);
                      if (v == 'save_all') _exportBatch(shareMode: false);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'share_all', child: ListTile(
                        leading: Icon(Icons.share_rounded),
                        title: Text('Share all as ZIP'),
                        dense: true,
                      )),
                      PopupMenuItem(value: 'save_all', child: ListTile(
                        leading: Icon(Icons.drive_folder_upload_rounded),
                        title: Text('Save all to folder'),
                        dense: true,
                      )),
                    ],
                  ),
                ],
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: _loadRecordings,
                ),
              ],
      ),
      body: Stack(
        children: [
          // ── Main content ──────────────────────────────────────────────────
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _recordings.isEmpty
                  ? _buildEmptyState(theme)
                  : _buildList(theme),

          // ── Export progress overlay ───────────────────────────────────────
          if (_isExporting)
            Container(
              color: Colors.black45,
              child: Center(
                child: Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text('Exporting recordings…',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ]),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.videocam_off_rounded, size: 80,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text('No recordings yet',
              style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Call recordings will appear here automatically.',
              style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: _recordings.length,
      itemBuilder: (context, index) => _buildRecordingCard(theme, _recordings[index]),
    );
  }

  Widget _buildRecordingCard(ThemeData theme, File file) {
    final isSelected = _selected.contains(file.path);
    final isPlaying = _playingFilePath == file.path;
    final isAudio = _isAudio(file.path);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isSelected
              ? theme.colorScheme.primary
              : theme.dividerColor.withValues(alpha: 0.5),
          width: isSelected ? 2 : 1,
        ),
        color: isSelected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.18)
            : theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            if (_selectionMode) {
              setState(() {
                if (isSelected) { _selected.remove(file.path); }
                else { _selected.add(file.path); }
                if (_selected.isEmpty) { _selectionMode = false; }
              });
            } else {
              _togglePlay(file.path);
            }
          },
          onLongPress: () {
            if (!_selectionMode) {
              setState(() {
                _selectionMode = true;
                _selected.add(file.path);
              });
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header row ──────────────────────────────────────────
                Row(children: [
                  // Selection checkbox or icon
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _selectionMode
                        ? Checkbox(
                            key: ValueKey(file.path),
                            value: isSelected,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6)),
                            onChanged: (v) {
                              setState(() {
                                if (v == true) { _selected.add(file.path); }
                                else { _selected.remove(file.path); }
                                if (_selected.isEmpty) { _selectionMode = false; }
                              });
                            },
                          )
                        : Container(
                            key: ValueKey('icon_${file.path}'),
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              isAudio
                                  ? Icons.graphic_eq_rounded
                                  : Icons.video_library_rounded,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  // Name + date
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_displayName(file),
                            style: TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(_formatDate(file.lastModifiedSync()),
                            style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurfaceVariant)),
                        Text(_formatFileSize(file.lengthSync()),
                            style: TextStyle(
                                fontSize: 10,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.7))),
                      ],
                    ),
                  ),
                  // Action buttons (hidden in selection mode)
                  if (!_selectionMode) ...[
                    _actionIconBtn(
                      icon: isPlaying
                          ? Icons.stop_circle_rounded
                          : Icons.play_circle_fill_rounded,
                      color: isPlaying ? Colors.red : Colors.green,
                      tooltip: isPlaying ? 'Stop' : 'Play',
                      onTap: () => _togglePlay(file.path),
                    ),
                    _actionIconBtn(
                      icon: Icons.more_vert_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                      tooltip: 'More options',
                      onTap: () => _showOptionsSheet(context, file, theme),
                    ),
                  ],
                ]),

                // ── Playback progress bar (shown while playing) ──────────
                if (isPlaying && _playbackDur.inSeconds > 0) ...[
                  const SizedBox(height: 10),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      value: _playbackPos.inMilliseconds
                          .clamp(0, _playbackDur.inMilliseconds)
                          .toDouble(),
                      max: _playbackDur.inMilliseconds.toDouble(),
                      onChanged: (v) {
                        _audioPlayer.seek(Duration(milliseconds: v.toInt()));
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(children: [
                      Text(_formatDuration(_playbackPos),
                          style: TextStyle(
                              fontSize: 10,
                              color: theme.colorScheme.onSurfaceVariant)),
                      const Spacer(),
                      Text(_formatDuration(_playbackDur),
                          style: TextStyle(
                              fontSize: 10,
                              color: theme.colorScheme.onSurfaceVariant)),
                    ]),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionIconBtn({required IconData icon, required Color color, required String tooltip, required VoidCallback onTap}) {
    return IconButton(
      icon: Icon(icon, color: color, size: 28),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }

  // ── Bottom sheet: per-recording actions ───────────────────────────────────
  void _showOptionsSheet(BuildContext context, File file, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(width: 36, height: 4,
              decoration: BoxDecoration(color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(_displayName(file),
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: 8),
          _sheetTile(Icons.share_rounded, 'Share', 'Send to apps, contacts, cloud…',
              theme, () { Navigator.pop(context); _shareRecording(file); }),
          _sheetTile(Icons.drive_folder_upload_rounded, 'Export to Folder',
              'Save a copy to a folder of your choice', theme,
              () { Navigator.pop(context); _exportToFolder(file); }),
          _sheetTile(Icons.open_in_new_rounded, 'Open in External App',
              'Play with your default media player', theme,
              () { Navigator.pop(context); OpenFilex.open(file.path); }),
          const Divider(height: 1),
          _sheetTile(Icons.delete_outline_rounded, 'Delete', 'Permanently remove this recording',
              theme, () { Navigator.pop(context); _confirmDelete(context, file); },
              color: Colors.red),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _sheetTile(IconData icon, String title, String subtitle, ThemeData theme,
      VoidCallback onTap, {Color? color}) {
    final c = color ?? theme.colorScheme.onSurface;
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: c, size: 20),
      ),
      title: Text(title,
          style: TextStyle(fontWeight: FontWeight.w700, color: c)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant)),
      onTap: onTap,
    );
  }

  void _confirmDelete(BuildContext ctx, File file) {
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Delete Recording?'),
        content: Text('Delete "${_displayName(file)}"?\nThis cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () { Navigator.pop(ctx); _deleteRecording(file); },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteSelected(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: Text('Delete ${_selected.length} recordings?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () { Navigator.pop(ctx); _deleteSelected(); },
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
  }
}
