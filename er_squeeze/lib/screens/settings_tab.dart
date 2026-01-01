import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/folder_job.dart';
import '../models/job_status.dart';
import '../services/compression_manager.dart';
import '../services/storage.dart';

/// Lightweight representation of a video album/bucket from MediaStore.
class _AlbumInfo {
  final String id;
  final String name;

  const _AlbumInfo({required this.id, required this.name});
}

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key, this.goToStatusTab});
  final VoidCallback? goToStatusTab;

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  final _storage = StorageService();
  final _manager = CompressionManager();

  /// Jobs for albums that are currently selected for compression.
  Map<String, FolderJob> _jobs = {};

  /// All video albums discovered on device.
  List<_AlbumInfo> _albums = [];

  /// Set of album ids that the user has checked.
  Set<String> _selectedAlbumIds = <String>{};

  final TextEditingController _suffixCtl = TextEditingController();
  bool _keepOriginal = false;

  // Old files tracking (trash)
  int _oldCount = 0;
  int _oldBytes = 0;

  bool get _hasOldFiles => _oldCount > 0;

  // ✅ NEW: initial loading gate
  bool _isInitialLoading = true;

  bool get _shouldDisableStart {
    if (_manager.isRunning) return false; // allow stopping while running

    // 🔒 Block starting compression if there are old files pending deletion.
    if (_hasOldFiles) return true;

    if (_selectedAlbumIds.isEmpty) return true;
    if (_keepOriginal && _suffixCtl.text.trim().isEmpty) return true;
    return false;
  }

  static const String _albumsInfoText =
      'Squeeze! will compress all videos inside the albums you select below.\n\n'
      '• If you select a few albums, only videos in those albums are compressed.\n'
      '• If you select all albums, all videos on your device will be compressed.';

  @override
  void initState() {
    super.initState();
    _runInitialLoad();
  }

  @override
  void dispose() {
    _suffixCtl.dispose();
    super.dispose();
  }

  Future<void> _runInitialLoad() async {
    if (mounted) setState(() => _isInitialLoading = true);

    try {
      // We do this in a safe order:
      // 1) load albums (permission + MediaStore scan)
      // 2) load persisted jobs/options
      // 3) load old files stats
      await _loadAlbumsForSelection();
      await _loadPersistedState();
      await _loadOldFilesStats();
    } finally {
      if (mounted) setState(() => _isInitialLoading = false);
    }
  }

  Future<bool> _confirmOriginalsWillBeDeleted() async {
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start compression'),
        content: const Text(
          'Your original videos will be replaced with compressed versions.\n\n'
          'The originals will be kept as "old files" which you can '
          'delete in Squeeze!.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('I understand, start'),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Permissions (Media / Notify)
  // ────────────────────────────────────────────────────────────────────────────

  Future<bool> _ensureMediaPermission() async {
    if (!Platform.isAndroid) return true;

    final ps = await PhotoManager.requestPermissionExtend();
    if (ps.isAuth || ps.hasAccess) {
      return true;
    }

    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Allow access to videos'),
          content: const Text(
            'Squeeze! needs access to your videos in order to compress them. '
            'Please allow access in the system dialog or app settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                PhotoManager.openSetting();
                Navigator.of(ctx).pop();
              },
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    }
    return false;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Old files (trash) stats
  // ────────────────────────────────────────────────────────────────────────────

  Future<void> _loadOldFilesStats() async {
    int count = 0;
    int bytes = 0;

    try {
      final items = await _storage.loadTrash();
      count = items.length;
      for (final item in items) {
        bytes += item.bytes;
      }
    } catch (_) {
      count = 0;
      bytes = 0;
    }

    _oldCount = count;
    _oldBytes = bytes;
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double v = bytes.toDouble();
    int i = 0;
    while (v >= 1000 && i < units.length - 1) {
      v /= 1000;
      i++;
    }
    return '${v.toStringAsFixed(1)} ${units[i]}';
  }

  Widget _buildOldFilesBanner(BuildContext context) {
    if (!_hasOldFiles) return const SizedBox.shrink();

    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Clear old files',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Before starting a new compression run, please clear your old files.\n\n'
              'There ${_oldCount == 1 ? 'is' : 'are'} $_oldCount old '
              '${_oldCount == 1 ? 'video' : 'videos'} that can now be deleted '
              '(${_formatBytes(_oldBytes)}).',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: () async {
                    await _clearOldFilesAndRefresh();
                  },
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('Clear old files now'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clearOldFilesAndRefresh() async {
    await _manager.clearOldFiles();
    await _loadOldFilesStats();
    if (mounted) setState(() {});
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Loading & persistence
  // ────────────────────────────────────────────────────────────────────────────

  Future<void> _loadPersistedState() async {
    final jobs = await _storage.loadJobs();
    final options = await _storage.loadOptions();

    _suffixCtl.text = (options['suffix'] ?? '').toString();
    _keepOriginal = (options['keepOriginal'] ?? false) as bool;

    final selected = (options['selectedFolders'] as List?)?.cast<String>() ??
        const <String>[];

    if (selected.isEmpty && jobs.isNotEmpty) {
      _selectedAlbumIds = jobs.keys.toSet();
    } else {
      _selectedAlbumIds = selected.toSet();
    }

    _jobs = {
      for (final e in jobs.entries)
        if (_selectedAlbumIds.contains(e.key)) e.key: e.value,
    };
  }

  void _resetAllJobsProgress(Map<String, FolderJob> jobs) {
    for (final job in jobs.values) {
      job.processedBytes = 0;
      job.totalBytes = 0;
      job.currentFilePath = null;
      job.completedSizes.clear();
      job.compressedPaths.clear();
      job.fileIndex.clear();
      job.status = JobStatus.notStarted;
    }
  }

  Future<void> _clearSuffixAndPersist() async {
    if (_suffixCtl.text.isEmpty) return;
    _suffixCtl.text = '';
    await _storage.saveOptions(suffix: '');
    if (mounted) setState(() {});
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Album discovery & selection (MediaStore)
  // ────────────────────────────────────────────────────────────────────────────

  Future<void> _loadAlbumsForSelection() async {
    final ok = await _ensureMediaPermission();
    if (!ok) {
      _albums = [];
      return;
    }

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
    );

    _albums = paths
        .map((p) => _AlbumInfo(id: p.id, name: p.name))
        .toList(growable: false);
  }

  Future<void> _indexAllAlbumsJobs() async {
    _jobs.clear();

    final ok = await _ensureMediaPermission();
    if (!ok) return;

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
    );

    for (final path in paths) {
      _jobs[path.id] = FolderJob(
        displayName: path.name,
        folderPath: path.id,
        recursive: true,
      );
    }

    _selectedAlbumIds = _jobs.keys.toSet();

    await _storage.saveJobs(_jobs);
    await _storage.saveOptions(selectedFolders: _jobs.keys.toList());

    if (mounted) setState(() {});
  }

  Future<void> _toggleAlbumSelection(_AlbumInfo album, bool selected) async {
    if (selected) {
      _selectedAlbumIds.add(album.id);
      _jobs[album.id] = _jobs[album.id] ??
          FolderJob(
            displayName: album.name,
            folderPath: album.id,
            recursive: true,
          );
    } else {
      _selectedAlbumIds.remove(album.id);
      _jobs.remove(album.id);
    }

    await _storage.saveJobs(_jobs);
    await _storage.saveOptions(
      selectedFolders: _selectedAlbumIds.toList(),
    );

    if (mounted) setState(() {});
  }

  Future<void> _setAllAlbumSelections(bool selected) async {
    if (_albums.isEmpty) return;

    if (selected) {
      _selectedAlbumIds = _albums.map((a) => a.id).toSet();
      for (final album in _albums) {
        _jobs[album.id] = _jobs[album.id] ??
            FolderJob(
              displayName: album.name,
              folderPath: album.id,
              recursive: true,
            );
      }
    } else {
      _selectedAlbumIds.clear();
      _jobs.clear();
    }

    await _storage.saveJobs(_jobs);
    await _storage.saveOptions(
      selectedFolders: _selectedAlbumIds.toList(),
    );

    if (mounted) setState(() {});
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Start / Stop
  // ────────────────────────────────────────────────────────────────────────────

  Future<void> _onStartStopPressed() async {
    if (_isLocked) {
      _selectedAlbumIds.clear();
      _jobs.clear();
      await _storage.saveJobs({});
      await _storage.saveOptions(selectedFolders: []);
      _albums = [];
      if (mounted) setState(() {});

      await _manager.stopAndWait();

      // Re-run our initial loads after stopping
      await _runInitialLoad();
      return;
    }

    // Hard stop: must clear old files first
    if (_hasOldFiles) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please clear old files before starting compression.'),
        ),
      );
      return;
    }

    final bool needsWarning = !_keepOriginal;
    if (needsWarning) {
      final ok = await _confirmOriginalsWillBeDeleted();
      if (!ok) return;
    }

    final bool isCompressAll =
        _albums.isNotEmpty && _selectedAlbumIds.length == _albums.length;

    if (isCompressAll) {
      await _indexAllAlbumsJobs();
    } else {
      await _storage.saveJobs(_jobs);
      await _storage.saveOptions(
        selectedFolders: _selectedAlbumIds.toList(),
      );
    }

    await _storage.saveOptions(
      suffix: _suffixCtl.text.trim(),
      keepOriginal: _keepOriginal,
    );

    final jobs = await _storage.loadJobs();
    _resetAllJobsProgress(jobs);
    await _storage.saveJobs(jobs);

    if (Platform.isAndroid) {
      await Permission.notification.request();
    }

    // ignore: unawaited_futures
    _manager.start();
    widget.goToStatusTab?.call();
    if (mounted) setState(() {});
  }

  bool get _isLocked => _manager.isRunning || _manager.isPaused;

  Widget _disabledWhenLocked({required Widget child}) {
    return Opacity(
      opacity: _isLocked ? 0.5 : 1,
      child: AbsorbPointer(absorbing: _isLocked, child: child),
    );
  }

  Widget _sectionDivider() => const Divider(height: 32, thickness: 1);

  Widget _albumRow({
    required _AlbumInfo album,
    required bool selected,
    required ValueChanged<bool> onChanged,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: selected,
            onChanged: _isLocked ? null : (v) => onChanged(v ?? false),
          ),
        ],
      ),
      title: Text(album.name),
      onTap: _isLocked ? null : () => onChanged(!selected),
    );
  }

  Widget _selectAllAlbumsRow({
    required bool allSelected,
    required ValueChanged<bool> onChanged,
  }) {
    return Opacity(
      opacity: 0.65,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: allSelected,
              onChanged: _isLocked ? null : (v) => onChanged(v ?? false),
            ),
          ],
        ),
        title: const Text('Select all albums'),
        onTap: _isLocked ? null : () => onChanged(!allSelected),
      ),
    );
  }

  Widget _startStopFab({required bool running}) {
    final disabled = _isInitialLoading ? true : _shouldDisableStart;

    final Color? bgColor =
        disabled ? null : (running ? Colors.red : Colors.green);

    final tooltip = _isInitialLoading
        ? 'Loading…'
        : (running
            ? 'Stop compression'
            : (_hasOldFiles
                ? 'Clear old files first'
                : (disabled
                    ? 'Select at least one album or uncheck “Keep original files”'
                    : 'Start compression')));

    return Tooltip(
      message: tooltip,
      child: FloatingActionButton.extended(
        onPressed: disabled ? null : _onStartStopPressed,
        backgroundColor: bgColor,
        foregroundColor: Colors.white,
        icon: Icon(
            running ? Icons.stop_circle_outlined : Icons.play_arrow_rounded),
        label: Text(running ? 'Stop compression' : 'Start compression'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitialLoading) {
      return Scaffold(
        appBar: AppBar(title: Text('Settings')),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final running = _manager.isRunning;
    final bool allSelected =
        _albums.isNotEmpty && _selectedAlbumIds.length == _albums.length;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _buildOldFilesBanner(context),

          // Albums header
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Albums',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  padding: const EdgeInsets.only(left: 8),
                  tooltip: 'More info',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('How album selection works'),
                        content: const Text(_albumsInfoText),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('OK'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          _disabledWhenLocked(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_albums.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Use the button below to scan for albums '
                          'on your device.',
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          onPressed: _isLocked
                              ? null
                              : () async {
                                  if (mounted) {
                                    setState(() => _isInitialLoading = true);
                                  }
                                  try {
                                    await _runInitialLoad();
                                  } finally {
                                    if (mounted) {
                                      setState(() => _isInitialLoading = false);
                                    }
                                  }
                                },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Reload albums & settings'),
                        ),
                      ],
                    ),
                  )
                else ...[
                  _selectAllAlbumsRow(
                    allSelected: allSelected,
                    onChanged: (val) async {
                      await _setAllAlbumSelections(val);
                    },
                  ),
                  const SizedBox(height: 4),
                  Column(
                    children: _albums
                        .map(
                          (album) => _albumRow(
                            album: album,
                            selected: _selectedAlbumIds.contains(album.id),
                            onChanged: (val) async {
                              await _toggleAlbumSelection(album, val);
                            },
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),

          _sectionDivider(),

          // Options
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Options',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  padding: const EdgeInsets.only(left: 8),
                  tooltip: 'More info',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Keep original files'),
                        content: const Text(
                          'Squeeze! will keep the original '
                          'versions of your videos. The compressed copies will be saved '
                          'with a suffix you choose.\n\n'
                          '• If this is enabled, you must enter a suffix such as "_compressed".\n\n'
                          '• If you turn OFF this option, Squeeze! will replace each original '
                          'video with its compressed version to save space.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('OK'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          _disabledWhenLocked(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CheckboxListTile(
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  value: _keepOriginal,
                  onChanged: _isLocked
                      ? null
                      : (v) async {
                          final next = (v ?? false);
                          setState(() => _keepOriginal = next);
                          if (!next) {
                            await _clearSuffixAndPersist();
                          }
                        },
                  title: const Text('Keep original files after compression'),
                ),
                if (_keepOriginal)
                  TextField(
                    controller: _suffixCtl,
                    onChanged: (_) => setState(() {}),
                    enabled: !_isLocked,
                    decoration: InputDecoration(
                      isDense: true,
                      label: Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(text: 'Compressed file suffix'),
                            TextSpan(
                              text: ' *',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                        ),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontSize: 14),
                      ),
                      floatingLabelStyle: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(fontSize: 12),
                      errorText:
                          (_keepOriginal && _suffixCtl.text.trim().isEmpty)
                              ? 'Suffix is required.'
                              : null,
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 64),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: _startStopFab(running: running),
    );
  }
}
