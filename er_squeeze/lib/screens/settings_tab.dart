import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/folder_job.dart';
import '../models/job_status.dart';
import '../services/compression_manager.dart';
import '../services/storage.dart';

class _AlbumInfo {
  final String id;
  final String name;

  /// Nullable so cached albums can be shown without rescanning PhotoManager.
  final AssetPathEntity? entity;

  const _AlbumInfo({
    required this.id,
    required this.name,
    this.entity,
  });
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

  // Resets when the app process restarts.
  // Used only to prevent repeated scans within the same session.
  static bool _albumCacheLoadedThisSession = false;

  DateTime? _albumCacheTimestamp;

  Map<String, FolderJob> _jobs = {};
  List<_AlbumInfo> _albums = [];
  List<_AlbumInfo> _blockedAlbums = [];

  Set<String> _selectedAlbumIds = <String>{};

  final TextEditingController _suffixCtl = TextEditingController();
  bool _keepOriginal = false;

  int _oldCount = 0;
  int _oldOriginalBytes = 0;
  int _oldCompressedBytes = 0;
  int _oldReclaimableBytes = 0;

  bool get _hasOldFiles => _oldCount > 0;

  // Only album sections show loading spinners
  bool _isAlbumsLoading = true;

  bool get _isLocked => _manager.isRunning || _manager.isPaused;

  bool get _shouldDisableStart {
    if (_manager.isRunning) return false;
    if (_isAlbumsLoading) return true;
    if (_hasOldFiles) return true;
    if (_selectedAlbumIds.isEmpty) return true;
    if (_keepOriginal && _suffixCtl.text.trim().isEmpty) return true;
    return false;
  }

  static const String _albumsInfoText =
      'Squeeze! will compress all videos inside the albums you select below.\n\n'
      '• If you select a few albums, only videos in those albums are compressed.\n'
      '• If you select all albums, all videos on your device will be compressed.';

  static const String _inaccessibleAlbumsInfoText =
      'These albums can’t be accessed by Squeeze due to Android storage restrictions '
      'or because they belong to other apps.';

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
    // 1) Load persisted options/jobs first
    await _loadPersistedState();
    if (mounted) setState(() {});

    // 2) Load old file stats
    await _loadOldFilesStats();
    if (mounted) setState(() {});

    // 3) Load cached albums immediately if present
    await _loadCachedAlbumsIntoUi();

    // 4) Decide whether to refresh
    final shouldRefresh = _shouldRefreshAlbumCache();

    if (shouldRefresh) {
      await _loadAlbumsForSelectionStreamingAndSaveCache();
    } else {
      if (mounted) setState(() => _isAlbumsLoading = false);
    }

    _albumCacheLoadedThisSession = true;
  }

  bool _shouldRefreshAlbumCache() {
    // Rule: If compression run in progress, never refresh.
    if (_isLocked) return false;

    // ✅ Your rule: refresh if the app was closed and reopened.
    // That means: on the first Settings load of a new app session, refresh.
    if (!_albumCacheLoadedThisSession) return true;

    // ✅ Also refresh if more than 1 day has passed since last scan
    // (only relevant if the app stays open that long, but keep it anyway).
    if (_albumCacheTimestamp == null) return true;
    final age = DateTime.now().difference(_albumCacheTimestamp!);
    return age > const Duration(days: 1);
  }

  Future<void> _loadCachedAlbumsIntoUi() async {
    if (mounted) {
      setState(() {
        _isAlbumsLoading = true;
        _albums = [];
        _blockedAlbums = [];
      });
    }

    final cache = await _storage.loadAlbumScanCache();

    if (!mounted) return;

    if (cache == null) {
      // No cache:
      // - If locked => do NOT scan => stop spinner to avoid infinite loading
      // - If not locked => scan will happen next => keep spinner on
      setState(() {
        _albumCacheTimestamp = null;
        _isAlbumsLoading = _isLocked ? false : true;
      });
      return;
    }

    _albumCacheTimestamp = cache.timestamp;

    setState(() {
      _albums = cache.albums
          .map((m) => _AlbumInfo(
                id: m['id'] ?? '',
                name: m['name'] ?? '',
                entity: null,
              ))
          .where((a) => a.id.trim().isNotEmpty)
          .toList();

      _blockedAlbums = cache.blocked
          .map((m) => _AlbumInfo(
                id: m['id'] ?? '',
                name: m['name'] ?? '',
                entity: null,
              ))
          .where((a) => a.id.trim().isNotEmpty)
          .toList();

      _isAlbumsLoading = false;
    });

    await _pruneBlockedFromSelectionAndPersist();
    if (mounted) setState(() {});
  }

  Future<bool> _confirmOriginalsWillBeDeleted() async {
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start compression'),
        content: const Text(
          '• Compressing videos will change their order in your Gallery.\n\n'
          '• If a video has been compressed previously, it will be skipped.',
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
            'To continue, please grant full access to all Photos and Videos.',
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

  Future<void> _loadOldFilesStats() async {
    int count = 0;
    int origBytes = 0;
    int compBytes = 0;

    try {
      final items = await _storage.loadTrashValidated();
      count = items.length;
      for (final item in items) {
        origBytes += item.bytes;
        compBytes += item.compressedBytes;
      }
    } catch (_) {
      count = 0;
      origBytes = 0;
      compBytes = 0;
    }

    _oldCount = count;
    _oldOriginalBytes = origBytes;
    _oldCompressedBytes = compBytes;
    _oldReclaimableBytes = (origBytes - compBytes).clamp(0, origBytes);
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

    final reclaimStr = _formatBytes(_oldReclaimableBytes);
    final origStr = _formatBytes(_oldOriginalBytes);
    final compStr = _formatBytes(_oldCompressedBytes);

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
            const SizedBox(height: 6),
            Text(
              'Before starting a new compression run, please clear your old files.\n\n'
              'There ${_oldCount == 1 ? 'is' : 'are'} $_oldCount old '
              '${_oldCount == 1 ? 'video' : 'videos'} ready.\n\n'
              'Squeeze! summary:\n'
              '• Original videos: $origStr\n'
              '• Compressed videos: $compStr\n'
              '• Saved space: $reclaimStr',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
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

  Future<void> _pruneBlockedFromSelectionAndPersist() async {
    if (_blockedAlbums.isEmpty) return;

    final blockedIds = _blockedAlbums.map((a) => a.id).toSet();
    final hadBlockedSelection = _selectedAlbumIds.any(blockedIds.contains);
    final hadBlockedJobs = _jobs.keys.any(blockedIds.contains);

    if (!hadBlockedSelection && !hadBlockedJobs) return;

    _selectedAlbumIds.removeWhere(blockedIds.contains);
    _jobs.removeWhere((k, _) => blockedIds.contains(k));

    final persistedJobs = await _storage.loadJobs();
    for (final bid in blockedIds) {
      persistedJobs.remove(bid);
    }
    await _storage.saveJobs(persistedJobs);
    await _storage.saveOptions(selectedFolders: _selectedAlbumIds.toList());
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

  Future<void> _loadAlbumsForSelectionStreamingAndSaveCache() async {
    if (_isLocked) return;

    if (mounted) {
      setState(() {
        _isAlbumsLoading = true;
        _albums = [];
        _blockedAlbums = [];
      });
    }

    final ok = await _ensureMediaPermission();
    if (!ok) {
      if (mounted) {
        setState(() {
          _isAlbumsLoading = false;
          _albums = [];
          _blockedAlbums = [];
        });
      }
      return;
    }

    final paths = await PhotoManager.getAssetPathList(type: RequestType.video);

    final List<_AlbumInfo> accessible = [];
    final List<_AlbumInfo> blocked = [];

    for (final path in paths) {
      if (!mounted) return;
      if (_isLocked) return;

      final canAccess = await _manager.canAccessAlbum(path);
      final info = _AlbumInfo(id: path.id, name: path.name, entity: path);

      setState(() {
        if (!canAccess) {
          blocked.add(info);
          _blockedAlbums.add(info);
        } else {
          accessible.add(info);
          _albums.add(info);
        }
      });
    }

    await _pruneBlockedFromSelectionAndPersist();

    if (_isLocked) return;

    final ts = DateTime.now();
    _albumCacheTimestamp = ts;

    await _storage.saveAlbumScanCache(
      timestamp: ts,
      albums: accessible
          .map((a) => <String, String>{'id': a.id, 'name': a.name})
          .toList(),
      blocked: blocked
          .map((a) => <String, String>{'id': a.id, 'name': a.name})
          .toList(),
    );

    if (mounted) {
      setState(() {
        _isAlbumsLoading = false;
      });
    }
  }

  Future<void> _indexAllAlbumsJobs() async {
    _jobs.clear();

    final ok = await _ensureMediaPermission();
    if (!ok) return;

    for (final album in _albums) {
      _jobs[album.id] = FolderJob(
        displayName: album.name,
        folderPath: album.id,
        recursive: true,
      );
    }

    _selectedAlbumIds = _jobs.keys.toSet();

    await _storage.saveJobs(_jobs);
    await _storage.saveOptions(selectedFolders: _jobs.keys.toList());

    if (mounted) setState(() {});
  }

  Future<void> _toggleAlbumSelection(_AlbumInfo album, bool selected) async {
    if (_blockedAlbums.any((a) => a.id == album.id)) return;

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

  Future<void> _onStartStopPressed() async {
    if (_isLocked) {
      _selectedAlbumIds.clear();
      _jobs.clear();
      await _storage.saveJobs({});
      await _storage.saveOptions(selectedFolders: []);
      _albums = [];
      _blockedAlbums = [];
      _isAlbumsLoading = true;
      if (mounted) setState(() {});

      await _manager.stopAndWait();
      await _runInitialLoad();
      return;
    }

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

  Widget _inlineLoadingRow() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox(width: 8),
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: 12),
          Text('Loading…'),
        ],
      ),
    );
  }

  Widget _buildAlbumsSectionBody() {
    final bool allSelected =
        _albums.isNotEmpty && _selectedAlbumIds.length == _albums.length;

    if (_albums.isEmpty && _isAlbumsLoading) {
      return _inlineLoadingRow();
    }

    if (_albums.isEmpty && !_isAlbumsLoading) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isLocked
                  ? 'Albums can’t be refreshed while compression is running.'
                  : 'No albums loaded yet.',
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        _selectAllAlbumsRow(
          allSelected: allSelected,
          onChanged: (val) async {
            await _setAllAlbumSelections(val);
          },
        ),
        const SizedBox(height: 4),
        ..._albums.map(
          (album) => _albumRow(
            album: album,
            selected: _selectedAlbumIds.contains(album.id),
            onChanged: (val) async {
              await _toggleAlbumSelection(album, val);
            },
          ),
        ),
        if (_isAlbumsLoading) _inlineLoadingRow(),
      ],
    );
  }

  Widget _buildInaccessibleAlbumsSection(BuildContext context) {
    final shouldShow = _isAlbumsLoading || _blockedAlbums.isNotEmpty;
    if (!shouldShow) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Inaccessible albums',
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
                      title: const Text('Inaccessible albums'),
                      content: const Text(_inaccessibleAlbumsInfoText),
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
        if (_blockedAlbums.isNotEmpty)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              children: _blockedAlbums
                  .map(
                    (a) => ListTile(
                      leading: const Icon(Icons.lock_outline),
                      title: Text(a.name),
                    ),
                  )
                  .toList(),
            ),
          ),
        if (_blockedAlbums.isEmpty && _isAlbumsLoading) _inlineLoadingRow(),
      ],
    );
  }

  Widget _startStopFab({required bool running}) {
    final disabled = _shouldDisableStart;

    final Color? bgColor =
        disabled ? null : (running ? Colors.red : Colors.green);

    final tooltip = _isAlbumsLoading
        ? 'Loading albums…'
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
          running ? Icons.stop_circle_outlined : Icons.play_arrow_rounded,
        ),
        label: Text(running ? 'Stop compression' : 'Start compression'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = _manager.isRunning;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _buildOldFilesBanner(context),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Albums to compress',
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
                _buildAlbumsSectionBody(),
                _buildInaccessibleAlbumsSection(context),
              ],
            ),
          ),
          _sectionDivider(),
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
                          'If enabled, Squeeze will keep originals and save compressed copies with a suffix.\n\n'
                          'If disabled, Squeeze will replace originals after you clear old files.',
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
