main.dart
import 'package:flutter/material.dart';
import 'screens/home_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Squeeze!',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true),
      home: const HomeShell(),
    );
  }
}
--------------------------------------------------------------------------------

models/folder_job.dart
import 'dart:convert';
import 'job_status.dart';

class FileState {
  final int originalBytes;
  final bool compressed;

  const FileState({required this.originalBytes, required this.compressed});

  Map<String, dynamic> toMap() => {
        'originalBytes': originalBytes,
        'compressed': compressed,
      };

  static FileState fromMap(Map<String, dynamic> m) => FileState(
        originalBytes: (m['originalBytes'] ?? 0) as int,
        compressed: (m['compressed'] ?? false) as bool,
      );
}

class FolderJob {
  /// Display name shown in the UI. For MediaStore this is the album/bucket name.
  final String displayName;

  /// Identifier of the underlying source.
  ///
  /// - For MediaStore-based scanning, this is the `AssetPathEntity.id` (album id).
  /// - Older versions may have persisted an absolute filesystem path.
  final String folderPath;

  final bool recursive;
  JobStatus status;

  int totalBytes;
  int processedBytes;

  /// Arbitrary label for the current file (e.g. filename).
  /// Old persisted data might contain a full path; we only ever display this.
  String? currentFilePath;

  String? errorMessage;

  /// Index of all videos for this job. Keys are logical file identifiers:
  /// - For MediaStore, these are `AssetEntity.id`s.
  Map<String, FileState> fileIndex;

  /// Map of completed file ids → original sizes (bytes).
  Map<String, int> completedSizes;

  /// Set of paths of compressed outputs, kept for backward compatibility.
  Set<String> compressedPaths;

  FolderJob({
    required this.displayName,
    required this.folderPath,
    this.recursive = false,
    this.status = JobStatus.notStarted,
    this.totalBytes = 0,
    this.processedBytes = 0,
    this.currentFilePath,
    Map<String, FileState>? fileIndex,
    Map<String, int>? completedSizes,
    Set<String>? compressedPaths,
  })  : fileIndex = fileIndex ?? <String, FileState>{},
        completedSizes = completedSizes ?? <String, int>{},
        compressedPaths = compressedPaths ?? <String>{};

  int get mappedTotalBytes =>
      fileIndex.values.fold(0, (a, f) => a + f.originalBytes);

  int get mappedCompressedBytes => fileIndex.entries
      .where((e) => e.value.compressed)
      .fold(0, (a, e) => a + e.value.originalBytes);

  Map<String, dynamic> toMap() => {
        'displayName': displayName,
        'folderPath': folderPath,
        'recursive': recursive,
        'status': status.index,
        'totalBytes': totalBytes,
        'processedBytes': processedBytes,
        'currentFilePath': currentFilePath,
        'fileIndex': {
          for (final e in fileIndex.entries) e.key: e.value.toMap(),
        },
        'completedSizes': completedSizes,
        'compressedPaths': compressedPaths.toList(),
      };

  static FolderJob fromMap(Map<String, dynamic> m) => FolderJob(
        displayName: m['displayName'],
        folderPath: m['folderPath'],
        recursive: (m['recursive'] ?? false) as bool,
        status: JobStatus.values[(m['status'] ?? 0) as int],
        totalBytes: (m['totalBytes'] ?? 0) as int,
        processedBytes: (m['processedBytes'] ?? 0) as int,
        currentFilePath: m['currentFilePath'],
        fileIndex: {
          for (final e
              in (m['fileIndex'] as Map? ?? const <String, dynamic>{}).entries)
            e.key: FileState.fromMap(Map<String, dynamic>.from(e.value)),
        },
        completedSizes: Map<String, int>.from(m['completedSizes'] ?? const {}),
        compressedPaths: ((m['compressedPaths'] ?? const <String>[]) as List)
            .map((e) => e.toString())
            .toSet(),
      );

  String toJson() => jsonEncode(toMap());
  static FolderJob fromJson(String s) => fromMap(jsonDecode(s));

  /// For legacy UI – now just returns [s] as-is, since [folderPath] is no longer an FS path.
  static String getPrettyFolderPath(String s) => s;
}
--------------------------------------------------------------------------------

models/job_status.dart
enum JobStatus { notStarted, inProgress, completed }
--------------------------------------------------------------------------------

models/scan_result.dart
import 'dart:io';

class ScanResult {
  final List<File> files;
  final int totalBytes;
  const ScanResult(this.files, this.totalBytes);
}
--------------------------------------------------------------------------------

models/trash_item.dart
class TrashItem {
  /// Filesystem path of the original media file.
  final String originalPath;

  /// Filesystem path of the compressed temp file that should replace
  /// [originalPath] once the user confirms deletion.
  final String trashedPath;

  /// Original size in bytes (before compression).
  final int bytes;

  /// Compressed size in bytes (temp file size).
  final int compressedBytes;

  /// Original container extension (e.g. ".mp4", ".mov").
  /// Used for preview breakdown + some sanity checks.
  final String originalExt;

  /// When this item was added to the "old files" list.
  final DateTime trashedAt;

  /// MediaStore / photo_manager asset id for the original.
  final String assetId;

  const TrashItem({
    required this.originalPath,
    required this.trashedPath,
    required this.bytes,
    required this.compressedBytes,
    required this.originalExt,
    required this.trashedAt,
    required this.assetId,
  });

  Map<String, dynamic> toMap() => {
        'originalPath': originalPath,
        'trashedPath': trashedPath,
        'bytes': bytes,
        'compressedBytes': compressedBytes,
        'originalExt': originalExt,
        'trashedAt': trashedAt.toIso8601String(),
        'assetId': assetId,
      };

  static TrashItem fromMap(Map<String, dynamic> m) => TrashItem(
        originalPath: (m['originalPath'] ?? '') as String,
        trashedPath: (m['trashedPath'] ?? '') as String,
        bytes: (m['bytes'] ?? 0) as int,
        compressedBytes: (m['compressedBytes'] ?? 0) as int,
        originalExt: (m['originalExt'] ?? '') as String,
        trashedAt: DateTime.tryParse(m['trashedAt'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        assetId: (m['assetId'] ?? '') as String,
      );
}
--------------------------------------------------------------------------------

screens/about_tab.dart
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutTab extends StatefulWidget {
  const AboutTab({super.key});
  @override
  State<AboutTab> createState() => _AboutTabState();
}

class _AboutTabState extends State<AboutTab> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      setState(() {
        _version = '${info.version}+${info.buildNumber}';
      });
    } catch (_) {
      setState(() => _version = 'Unknown');
    }
  }

  @override
  Widget build(BuildContext context) {
    const appName = 'Squeeze!';
    const description = 'Compress videos on your device to save space.';

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(appName,
                        style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(description),
                    const SizedBox(height: 8),
                    Text('Version: $_version',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: Colors.black54)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ExpansionTile(
            title: const Text('Licenses'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              LicenseCard(
                title: 'This app ($appName)',
                subtitle: 'GNU General Public License v3.0 (GPL-3.0)',
                notice: '''
This application is licensed under the GNU General Public License version 3 (GPLv3).
You are free to run, study, share, and modify the software under the terms of the GPLv3.
A copy of the GPLv3 license text should be provided with the distribution.
For details, see https://github.com/ertelek/squeeze/blob/main/LICENSE
''',
                url: 'https://github.com/ertelek/squeeze/blob/main/LICENSE',
              ),
              LicenseCard(
                title: 'FFmpeg Kit (ffmpeg_kit_flutter_new)',
                subtitle: 'GNU General Public License v3.0 (GPL-3.0)',
                notice: '''
FFmpeg Kit (and the FFmpeg binaries it bundles in the GPL variant) are licensed under GPLv3 (and/or other compatible licenses for included libraries).
Source code and license details are available from the FFmpeg Kit project and FFmpeg upstream.
See https://github.com/sk3llo/ffmpeg_kit_flutter/blob/master/LICENSE
''',
                url: 'https://github.com/sk3llo/ffmpeg_kit_flutter/blob/master/LICENSE',
              ),
              LicenseCard(
                title: 'FFmpeg',
                subtitle:
                    'GNU Lesser General Public License (LGPL) v2.1 or later (GPL may apply if enabled components require it)',
                notice: '''
FFmpeg is licensed under the GNU Lesser General Public License (LGPL) version 2.1 or later.
However, FFmpeg incorporates several optional parts and optimizations that are covered by the GNU General Public License (GPL) version 2 or later.
If those parts get used the GPL applies to all of FFmpeg.
See https://www.ffmpeg.org/legal.html for the full text.
''',
                url: 'https://www.ffmpeg.org/legal.html',
              ),
              LicenseCard(
                title: 'x264',
                subtitle: 'GNU General Public License v2 or later (GPL-2.0+)',
                notice: '''
x264 is free software licensed under the GNU GPL version 2 (or, at your option, any later version).
See https://x264.org/licensing/ and the included COPYING file for the full text.
''',
                url: 'https://x264.org/licensing/',
              ),
              LicenseCard(
                title: 'Other Dart/Flutter packages',
                subtitle: 'Various open-source licenses',
                notice: '''
This app uses additional Dart/Flutter packages which include their own licenses.
You can view those licenses via the license screen below.
''',
                onTapOverride: () {
                  showLicensePage(
                    context: context,
                    applicationName: appName,
                    applicationVersion: _version,
                    applicationLegalese:
                        '© ${DateTime.now().year} The $appName contributors',
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              showLicensePage(
                context: context,
                applicationName: appName,
                applicationVersion: _version,
                applicationLegalese:
                    '© ${DateTime.now().year} The $appName contributors',
              );
            },
            icon: const Icon(Icons.article_outlined),
            label: const Text('View Dart/Flutter package licenses'),
          ),
        ],
      ),
    );
  }
}

class LicenseCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String notice;
  final String? url;
  final VoidCallback? onTapOverride;

  const LicenseCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.notice,
    this.url,
    this.onTapOverride,
  });

  Future<void> _openUrl(BuildContext context) async {
    if (onTapOverride != null) {
      onTapOverride!();
      return;
    }
    if (url == null || url!.isEmpty) return;

    final uri = Uri.tryParse(url!);
    if (uri == null) return;

    if (!await canLaunchUrl(uri)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
      return;
    }
    final ok = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openUrl(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.black54)),
              const SizedBox(height: 8),
              Text(
                notice.trim(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (url != null && url!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.open_in_new, size: 16),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        url!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              decoration: TextDecoration.underline,
                            ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
--------------------------------------------------------------------------------

screens/home_shell.dart
import 'package:flutter/material.dart';
import 'status_tab.dart';
import 'settings_tab.dart';
import 'about_tab.dart';
import '../services/storage.dart';
import '../services/compression_manager.dart';
import '../models/job_status.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int? _index; // null = deciding
  late final PageController _pageController;

  final _storage = StorageService();
  final _mgr = CompressionManager();
  final _statusKey = GlobalKey<StatusTabState>();

  @override
  void initState() {
    super.initState();
    _decideInitialTab();
    _autoResumeIfNeeded();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _autoResumeIfNeeded() async {
    final jobs = await _storage.loadJobs();
    final anyInProgress =
        jobs.values.any((j) => j.status == JobStatus.inProgress);
    if (anyInProgress && !_mgr.isRunning) {
      // ignore: unawaited_futures
      _mgr.start();
    }
  }

  Future<void> _decideInitialTab() async {
    if (_mgr.isRunning) {
      _index = 0;
    } else {
      final opts = await _storage.loadOptions();
      final selected =
          (opts['selectedFolders'] as List?)?.cast<String>() ?? const <String>[];
      _index = selected.isEmpty ? 1 : 0;
    }

    _pageController = PageController(initialPage: _index!);

    if (mounted) setState(() {});
    if (_index == 0) {
      _statusKey.currentState?.refreshJobs();
    }
  }

  void _goToStatusTab() {
    setState(() => _index = 0);
    _pageController.animateToPage(
      0,
      duration: const Duration(milliseconds: 10),
      curve: Curves.fastEaseInToSlowEaseOut,
    );
    _statusKey.currentState?.refreshJobs();
  }

  @override
  Widget build(BuildContext context) {
    if (_index == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (i) {
          setState(() => _index = i);
          if (i == 0) _statusKey.currentState?.refreshJobs();
        },
        children: [
          StatusTab(key: _statusKey),
          SettingsTab(goToStatusTab: _goToStatusTab),
          const AboutTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index!,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          _pageController.animateToPage(
            i,
            duration: const Duration(milliseconds: 10),
            curve: Curves.fastEaseInToSlowEaseOut,
          );
          if (i == 0) _statusKey.currentState?.refreshJobs();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'Status',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
          NavigationDestination(
            icon: Icon(Icons.info_outline),
            selectedIcon: Icon(Icons.info),
            label: 'About',
          ),
        ],
      ),
    );
  }
}
--------------------------------------------------------------------------------

screens/settings_tab.dart
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

  Map<String, FolderJob> _jobs = {};
  List<_AlbumInfo> _albums = [];
  Set<String> _selectedAlbumIds = <String>{};

  final TextEditingController _suffixCtl = TextEditingController();
  bool _keepOriginal = false;

  int _oldCount = 0;
  int _oldOriginalBytes = 0;
  int _oldCompressedBytes = 0;
  int _oldReclaimableBytes = 0;

  bool get _hasOldFiles => _oldCount > 0;

  bool _isInitialLoading = true;

  bool get _shouldDisableStart {
    if (_manager.isRunning) return false;
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
      // ✅ Validate against filesystem so we don't block if temp outputs are gone.
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

  Future<void> _onStartStopPressed() async {
    if (_isLocked) {
      _selectedAlbumIds.clear();
      _jobs.clear();
      await _storage.saveJobs({});
      await _storage.saveOptions(selectedFolders: []);
      _albums = [];
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
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: CircularProgressIndicator()),
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
                if (_albums.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Use the button below to scan for albums.'),
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
--------------------------------------------------------------------------------

screens/status_tab.dart
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/folder_job.dart';
import '../models/job_status.dart';
import '../models/trash_item.dart';
import '../services/compression_manager.dart';
import '../services/storage.dart';
import '../services/storage_space_helper.dart';

class StatusTab extends StatefulWidget {
  const StatusTab({super.key});
  @override
  State<StatusTab> createState() => StatusTabState();
}

class StatusTabState extends State<StatusTab> {
  Timer? _refreshTimer;
  final _storage = StorageService();
  final _mgr = CompressionManager();
  Map<String, FolderJob> _jobs = {};
  bool _showPct = true;

  int _oldCount = 0;
  int _oldOriginalBytes = 0;
  int _oldCompressedBytes = 0;
  int _oldReclaimableBytes = 0;

  int _freeBytes = 0;

  bool _isInitialLoading = true;

  @override
  void initState() {
    super.initState();
    _runInitialLoad();

    _refreshTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) {
        if (mounted) {
          refreshJobs();
          setState(() {});
        }
      },
    );
  }

  Future<void> _runInitialLoad() async {
    if (mounted) setState(() => _isInitialLoading = true);
    try {
      await refreshJobs();
    } finally {
      if (mounted) setState(() => _isInitialLoading = false);
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> refreshJobs() async {
    _jobs = await _storage.loadJobs();

    final opts = await _storage.loadOptions();
    final keepOriginal = (opts['keepOriginal'] ?? false) as bool;
    _showPct = !keepOriginal;

    await _loadOldFilesStats();
  }

  Future<void> _loadOldFilesStats() async {
    int count = 0;
    int origBytes = 0;
    int compBytes = 0;

    try {
      // ✅ Validate against filesystem so we don't lie to the user.
      final List<TrashItem> items = await _storage.loadTrashValidated();
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

    final free = await StorageSpaceHelper.getFreeBytes();

    _oldCount = count;
    _oldOriginalBytes = origBytes;
    _oldCompressedBytes = compBytes;
    _oldReclaimableBytes = (origBytes - compBytes).clamp(0, origBytes);
    _freeBytes = free;
  }

  Color _dotColorFor(FolderJob job) {
    switch (job.status) {
      case JobStatus.inProgress:
        return _mgr.isPaused ? Colors.yellow : Colors.green;
      case JobStatus.completed:
        return Colors.blue;
      case JobStatus.notStarted:
        return Colors.red;
    }
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

  Widget _buildStorageBanner(BuildContext context) {
    final freeStr =
        _freeBytes > 0 ? _formatBytes(_freeBytes) : 'Unknown / not available';

    return Card(
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.storage_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Free space on your device: $freeStr',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOldFilesBanner(BuildContext context) {
    final hasOldFiles = _oldCount > 0;

    final reclaimStr = _formatBytes(_oldReclaimableBytes);
    final origStr = _formatBytes(_oldOriginalBytes);
    final compStr = _formatBytes(_oldCompressedBytes);

    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 12),
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
              hasOldFiles
                  ? 'You have $_oldCount old ${_oldCount == 1 ? 'video' : 'videos'} ready.\n\n'
                      'Squeeze! summary:\n'
                      '• Original videos: $origStr\n'
                      '• Compressed videos: $compStr\n'
                      '• Saved space: $reclaimStr\n\n'
                      'Clearing old files permanently deletes the originals and keeps the compressed versions.'
                  : 'After compressing, your old files will appear here so you can delete them and free up space.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: hasOldFiles
                      ? () async {
                          await _clearOldFiles();
                        }
                      : null,
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

  Future<void> _clearOldFiles() async {
    await _mgr.clearOldFiles();
    await _loadOldFilesStats();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitialLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Status')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final runningOrPaused = _mgr.isRunning || _mgr.isPaused;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Status'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await refreshJobs();
          if (mounted) setState(() {});
        },
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _buildStorageBanner(context),
            _buildOldFilesBanner(context),
            ..._jobs.values.map((job) {
              final completedFileCount =
                  job.fileIndex.values.where((a) => a.compressed).length;
              final totalFileCount = job.fileIndex.length;
              final sizePct = totalFileCount == 0
                  ? 0.0
                  : ((completedFileCount / totalFileCount) * 100)
                      .clamp(0, 100)
                      .toDouble();

              return Card(
                child: ExpansionTile(
                  leading: Icon(
                    Icons.circle,
                    color: _dotColorFor(job),
                    size: 12,
                  ),
                  title: Text(job.displayName),
                  subtitle: (_showPct && job.status != JobStatus.completed)
                      ? Text('${sizePct.toStringAsFixed(1)}%')
                      : null,
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    _kv('Album', job.displayName),
                    if (_showPct)
                      _kv(
                        'Completed',
                        '$completedFileCount / $totalFileCount '
                            '(${sizePct.toStringAsFixed(1)}%)',
                      ),
                    if (job.currentFilePath != null)
                      _kv('Current file', job.currentFilePath!),
                  ],
                ),
              );
            }),
            const SizedBox(height: 64),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: runningOrPaused
          ? FloatingActionButton.extended(
              onPressed: () async {
                if (_mgr.isPaused) {
                  await _mgr.resume();
                } else {
                  await _mgr.pause();
                }
                if (mounted) setState(() {});
              },
              icon: Icon(_mgr.isPaused ? Icons.play_arrow : Icons.pause),
              label: Text('${_mgr.isPaused ? 'Resume' : 'Pause'} compression'),
            )
          : null,
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              child: Text(
                k,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(v)),
          ],
        ),
      );
}
--------------------------------------------------------------------------------

services/compression_manager.dart
import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/folder_job.dart';
import '../models/job_status.dart';
import '../models/trash_item.dart';
import '../services/foreground_notifier.dart';
import '../services/storage.dart';
import '../services/video_processor.dart';
import 'storage_space_helper.dart';

/// Coordinates scanning video albums via MediaStore (photo_manager),
/// re-encoding videos, progress accounting, and foreground notifications.
class CompressionManager {
  static final CompressionManager _instance = CompressionManager._();
  CompressionManager._();
  factory CompressionManager() => _instance;

  final StorageService _storage = StorageService();

  bool _isRunningFlag = false;
  bool _isPausedFlag = false;
  int? _activeFfmpegSessionId;
  Completer<void>? _stopBarrier;

  bool get isRunning => _isRunningFlag;
  bool get isPaused => _isPausedFlag;

  bool _isLastAssetInJob(FolderJob job, String assetId) {
    for (final entry in job.fileIndex.entries) {
      if (!entry.value.compressed && entry.key != assetId) {
        return false;
      }
    }
    return true;
  }

  Future<void> start() async {
    if (_isRunningFlag) return;

    _isRunningFlag = true;
    _isPausedFlag = false;
    _stopBarrier = Completer<void>();
    _log('Compression START');

    await ForegroundNotifier.init();
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }

    await ForegroundNotifier.start(
      title: 'Setting things up',
      text: 'Preparing to squeeze…',
    );

    // Ensure media permission (MediaStore / Photos).
    final ps = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        iosAccessLevel: IosAccessLevel.readWrite,
        androidPermission: AndroidPermission(
          type: RequestType.video,
          mediaLocation: false,
        ),
      ),
    );

    // ✅ If LIMITED access, do not start.
    // We need full access to reliably read/write and save compressed outputs.
    if (ps == PermissionState.limited) {
      _toast(
        'Please grant full media access in Settings to start compression.',
      );
      await _finish();
      return;
    }

    if (!(ps.isAuth || ps.hasAccess)) {
      _toast('Permission to access videos was denied.');
      await _finish();
      return;
    }

    final jobs = await _storage.loadJobs();
    final options = await _storage.loadOptions();
    final suffix = (options['suffix'] ?? '_compressed').toString();
    final keepOriginal = (options['keepOriginal'] ?? false) as bool;

    // Preload albums map: album id → AssetPathEntity
    final allPaths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
    );
    final Map<String, AssetPathEntity> pathById = {
      for (final pth in allPaths) pth.id: pth,
    };

    final videoProcessor = VideoProcessor();

    for (final entry in jobs.entries) {
      if (!_isRunningFlag) break;

      final job = entry.value;
      if (job.status == JobStatus.completed) continue;

      final pathEntity = pathById[job.folderPath];
      if (pathEntity == null) {
        _log('Album missing for job ${job.displayName} (${job.folderPath})');
        job.status = JobStatus.completed;
        await _storage.saveJobs(jobs);
        continue;
      }

      job.status = JobStatus.inProgress;
      await ForegroundNotifier.update(
        title: 'Squeezing ${job.displayName}',
        text: keepOriginal ? '' : _buildNotificationText(job),
      );
      await _storage.saveJobs(jobs);

      _log('Working on album: ${job.displayName} (id=${pathEntity.id})');

      // Index assets for this album (oldest → newest).
      await _indexAssetsForJob(pathEntity, job);
      await _storage.saveJobs(jobs);

      await ForegroundNotifier.update(
        title: 'Squeezing ${_composeDisplayTitle(job)}',
        text: keepOriginal ? '' : _buildNotificationText(job),
      );

      // Main processing loop
      while (_isRunningFlag) {
        if (_isPausedFlag) {
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }

        final asset = await _findNextAssetForJob(job);
        if (asset == null) {
          job.status = JobStatus.completed;
          await _storage.saveJobs(jobs);
          _log('Album completed: ${job.displayName}');
          break;
        }

        job.currentFilePath = asset.title ?? 'Video';
        await _storage.saveJobs(jobs);
        await ForegroundNotifier.update(
          title: 'Squeezing ${_composeDisplayTitle(job)}',
          text: keepOriginal ? '' : _buildNotificationText(job),
        );

        // ✅ storage warning
        await _checkStorageAndWarnIfLow(jobs);

        final file = await asset.file;
        if (file == null) {
          _log('Asset file is null for id=${asset.id}, skipping.');
          _markAssetDone(job, asset.id, 0);
          await _storage.saveJobs(jobs);
          continue;
        }

        // ✅ Skip if already tagged as Squeeze output
        final alreadyTagged =
            await videoProcessor.isAlreadyCompressedBySqueeze(file);
        if (alreadyTagged) {
          final originalSize = await videoProcessor.safeLength(file);
          _markAssetDone(job, asset.id, originalSize);
          await _storage.saveJobs(jobs);
          continue;
        }

        // ✅ Encode to app-private temp file, preserving container/extension
        final handle = await videoProcessor.encodeToTempSameContainer(
          file,
          targetCrf: 28,
        );
        _activeFfmpegSessionId = await handle.session.getSessionId();

        while (true) {
          if (!_isRunningFlag || _isPausedFlag) {
            final id = _activeFfmpegSessionId;
            if (id != null) {
              await FFmpegKit.cancel(id);
            }
            break;
          }
          final rc = await handle.session.getReturnCode();
          if (rc != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        final rc = await handle.session.getReturnCode();
        if (rc != null && rc.isValueSuccess()) {
          final originalSize = await videoProcessor.safeLength(file);
          final compressedSize =
              await videoProcessor.safeLength(handle.tempFile);

          // ✅ If output is not smaller: discard and keep original
          final smaller =
              await videoProcessor.isSmallerThanOriginal(file, handle.tempFile);
          if (!smaller) {
            await videoProcessor.discardTemp(handle.tempFile);
            _markAssetDone(job, asset.id, originalSize);
            await _storage.saveJobs(jobs);
            continue;
          }

          if (!keepOriginal) {
            // In-place semantics: defer delete+replace until user clears old files.
            final item = TrashItem(
              originalPath: file.path,
              trashedPath: handle.tempFile.path,
              bytes: originalSize,
              compressedBytes: compressedSize,
              originalExt: handle.ext,
              trashedAt: DateTime.now(),
              assetId: asset.id,
            );
            await _storage.addTrashItem(item);
            job.compressedPaths.add(handle.tempFile.path);
          } else {
            // Keep-original semantics: create a separate output next to the source.
            final srcExt = handle.ext;
            final stem = p.basenameWithoutExtension(file.path);
            final safeSuffix =
                suffix.trim().isEmpty ? '_compressed' : suffix.trim();
            final outPath = p.join(file.parent.path, '$stem$safeSuffix$srcExt');

            // Avoid collisions
            var finalOut = outPath;
            int counter = 1;
            while (await File(finalOut).exists()) {
              finalOut =
                  p.join(file.parent.path, '$stem$safeSuffix-$counter$srcExt');
              counter++;
            }

            await handle.tempFile.copy(finalOut);
            await videoProcessor.discardTemp(handle.tempFile);
            job.compressedPaths.add(finalOut);
          }

          _markAssetDone(job, asset.id, originalSize);
          await _storage.saveJobs(jobs);

          await ForegroundNotifier.update(
            title: 'Squeezing ${_composeDisplayTitle(job)}',
            text: keepOriginal ? '' : _buildNotificationText(job),
          );

          final isLast = _isLastAssetInJob(job, asset.id);
          if (!isLast) {
            for (int i = 0; i < 300; i++) {
              if (!_isRunningFlag || _isPausedFlag) break;
              await Future<void>.delayed(const Duration(seconds: 1));
            }
          }
        } else {
          try {
            final allLogs = await handle.session.getAllLogs();
            final output = allLogs.map((e) => e.getMessage()).join('\n');
            job.errorMessage = output;
          } catch (e) {
            job.errorMessage = e.toString();
          }

          await videoProcessor.discardTemp(handle.tempFile);

          _markAssetDone(job, asset.id, 0);
          await _storage.saveJobs(jobs);

          if (_isPausedFlag) {
            while (_isPausedFlag && _isRunningFlag) {
              await Future<void>.delayed(const Duration(milliseconds: 300));
            }
          } else if (!_isRunningFlag) {
            break;
          }
        }
      }
    }

    await _finish();
  }

  void _markAssetDone(FolderJob job, String id, int originalSize) {
    job.completedSizes[id] = originalSize;
    final prev = job.fileIndex[id];
    job.fileIndex[id] = FileState(
      originalBytes: prev?.originalBytes ?? originalSize,
      compressed: true,
    );
    job.totalBytes = job.mappedTotalBytes;
    job.processedBytes = job.mappedCompressedBytes;
  }

  Future<void> pause() async {
    _isPausedFlag = true;
    await ForegroundNotifier.update(
      text:
          'Paused • ${DateTime.now().toLocal().toString().split(' ')[1].substring(0, 8)}',
    );
    _log('PAUSE requested');
  }

  Future<void> resume() async {
    _isPausedFlag = false;
    await ForegroundNotifier.update(text: 'Resumed');
    _log('RESUME');
  }

  Future<void> stopAndWait(
      {Duration timeout = const Duration(seconds: 5)}) async {
    _isRunningFlag = false;
    _isPausedFlag = false;
    _log('STOP requested');

    final id = _activeFfmpegSessionId;
    if (id != null) {
      try {
        await FFmpegKit.cancel(id);
      } catch (_) {}
    }

    final future = _stopBarrier?.future;
    if (future != null) {
      try {
        await future.timeout(timeout);
      } catch (_) {}
    }
  }

  Future<void> stop() => stopAndWait();

  /// Called from the Status/Settings tab's "Clear old files" button.
  ///
  /// Deletes originals via MediaStore (user-confirmed) and then copies the temp
  /// compressed bytes back into the original path.
  ///
  /// ✅ No recycle-bin logic here: we just request deletion via deleteWithIds.
  Future<void> clearOldFiles() async {
    // ✅ Start from validated list so we don't ask for deletion if temp outputs vanished.
    final items = await _storage.loadTrashValidated();
    if (items.isEmpty) return;

    // 1) Ask Android/MediaStore to delete originals (user may deny).
    final ids = items
        .map((e) => e.assetId.trim())
        .where((id) => id.isNotEmpty)
        .toList();

    bool deleteCallFailed = false;
    if (ids.isNotEmpty) {
      try {
        await PhotoManager.editor.deleteWithIds(ids);
      } catch (e) {
        deleteCallFailed = true;
        _log('Failed to delete originals via MediaStore: $e');
        _toast(
            'Could not delete old videos. Please try again.');
      }
    }

    // 2) Verify per-item, finalize replacement, and only then remove from trash.
    final List<TrashItem> stillPending = [];

    for (final item in items) {
      final tempFile = File(item.trashedPath);

      final tempExists = await _safeExists(tempFile);

      if (!tempExists) {
        // Temp missing: can't finalize, drop it (and validation will keep list clean).
        continue;
      }

      final deleted = await _isOriginalDefinitelyDeleted(item);
      if (!deleted) {
        stillPending.add(item);
        continue;
      }

      final ok = await _finalizeReplacement(
        tempFile: tempFile,
        originalPath: item.originalPath,
      );

      if (!ok) {
        stillPending.add(item);
        continue;
      }
    }

    await _storage.saveTrash(stillPending);
    if (deleteCallFailed) return;
  }

  Future<bool> _safeExists(File f) async {
    try {
      return await f.exists();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isOriginalDefinitelyDeleted(TrashItem item) async {
    bool assetGone = false;
    bool pathGone = false;

    final id = item.assetId.trim();
    if (id.isNotEmpty) {
      try {
        final ent = await AssetEntity.fromId(id);
        assetGone = (ent == null);
      } catch (_) {
        assetGone = false;
      }
    }

    try {
      pathGone = !(await File(item.originalPath).exists());
    } catch (_) {
      pathGone = false;
    }

    if (id.isNotEmpty) return assetGone || pathGone;
    return pathGone;
  }

  Future<bool> _finalizeReplacement({
    required File tempFile,
    required String originalPath,
  }) async {
    try {
      final parent = Directory(File(originalPath).parent.path);
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }

      await tempFile.copy(originalPath);

      try {
        await tempFile.delete();
      } catch (_) {}

      return true;
    } catch (e) {
      _log('Failed to finalize replacement to $originalPath: $e');
      _toast('Failed to save a compressed file. Please try again.');
      return false;
    }
  }

  void _log(String message) {
    // print(message);
  }

  void _toast(String msg) {
    Fluttertoast.showToast(msg: msg, toastLength: Toast.LENGTH_LONG);
  }

  String _composeDisplayTitle(FolderJob job) => job.displayName;

  String _buildNotificationText(FolderJob job) {
    final completedFileCount =
        job.fileIndex.values.where((a) => a.compressed).length;
    final totalFileCount = job.fileIndex.length;
    return 'Completed: $completedFileCount / $totalFileCount (${_formatPercent(completedFileCount, totalFileCount)})';
  }

  String _formatPercent(int done, int total) {
    if (total <= 0) return '0%';
    final pct = (done / total * 100).clamp(0, 100);
    return '${pct.toStringAsFixed(1)}%';
  }

  int _bytesLeftAcrossJobs(Map<String, FolderJob> jobs) {
    var sum = 0;
    for (final job in jobs.values) {
      for (final entry in job.fileIndex.entries) {
        if (!entry.value.compressed) {
          sum += entry.value.originalBytes;
        }
      }
    }
    return sum;
  }

  Future<void> _checkStorageAndWarnIfLow(Map<String, FolderJob> jobs) async {
    if (!Platform.isAndroid) return;

    final freeBytes = await StorageSpaceHelper.getFreeBytes();
    final bytesLeft = _bytesLeftAcrossJobs(jobs);

    // ✅ Use validated trash: if temps are gone, don’t warn about “clear old files”.
    final hasPendingOldFiles = (await _storage.loadTrashValidated()).isNotEmpty;

    if (freeBytes <= 0 || bytesLeft <= 0 || !hasPendingOldFiles) return;

    if (freeBytes < bytesLeft * 2) {
      _toast('Storage is getting low. Open Squeeze and clear old files.');
      await ForegroundNotifier.update(
        text: 'Low storage: open Squeeze and clear old files',
      );

      final ratio = (bytesLeft * 2) / freeBytes;
      final seconds = (ratio * 5).clamp(3, 30).toInt();
      for (int i = 0; i < seconds; i++) {
        if (!_isRunningFlag || _isPausedFlag) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> _finish() async {
    try {
      // ✅ Only show "Tap to clear old files" if validated temps still exist.
      final pending = await _storage.loadTrashValidated();
      if (pending.isNotEmpty) {
        await ForegroundNotifier.update(
          title: 'Compression finished',
          text: 'Tap to clear old files.',
        );
      } else {
        await ForegroundNotifier.update(
          title: 'Compression finished',
        );
      }
    } catch (_) {}

    _isRunningFlag = false;
    _isPausedFlag = false;
    _activeFfmpegSessionId = null;
    await ForegroundNotifier.stop();

    if (!(_stopBarrier?.isCompleted ?? true)) {
      _stopBarrier!.complete();
    }
    _stopBarrier = null;
    _log('Compression STOP (done or stopped)');
  }

  Future<void> _indexAssetsForJob(
    AssetPathEntity pathEntity,
    FolderJob job,
  ) async {
    final List<_AssetMeta> metas = <_AssetMeta>[];

    try {
      final total = await pathEntity.assetCountAsync;
      const pageSize = 50;
      for (int start = 0; start < total; start += pageSize) {
        final end = (start + pageSize) > total ? total : (start + pageSize);
        final assets = await pathEntity.getAssetListRange(
          start: start,
          end: end,
        );
        for (final asset in assets) {
          if (asset.type != AssetType.video) continue;
          final id = asset.id;

          int sizeBytes = 0;
          try {
            final f = await asset.file;
            if (f != null) {
              sizeBytes = await f.length();
            }
          } catch (_) {
            sizeBytes = 0;
          }

          metas.add(_AssetMeta(
            id: id,
            originalBytes: sizeBytes,
            createdAt: asset.createDateTime,
          ));
        }
      }
    } catch (e) {
      _log('Error indexing assets for album ${job.displayName}: $e');
    }

    metas.sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final Map<String, FileState> nextIndex = <String, FileState>{};
    for (final meta in metas) {
      final alreadyCompressed = job.completedSizes.containsKey(meta.id);
      nextIndex[meta.id] = FileState(
        originalBytes: meta.originalBytes,
        compressed: alreadyCompressed,
      );
    }

    job.fileIndex = nextIndex;
    job.totalBytes = job.mappedTotalBytes;
    job.processedBytes = job.mappedCompressedBytes;
  }

  Future<AssetEntity?> _findNextAssetForJob(FolderJob job) async {
    for (final entry in job.fileIndex.entries) {
      final id = entry.key;
      final fs = entry.value;
      if (fs.compressed) continue;

      final asset = await AssetEntity.fromId(id);
      if (asset == null || asset.type != AssetType.video) {
        _markAssetDone(job, id, fs.originalBytes);
        final jobs = await _storage.loadJobs();
        await _storage.saveJobs(jobs);
        continue;
      }
      return asset;
    }
    return null;
  }
}

/// Internal metadata holder used when indexing albums.
class _AssetMeta {
  final String id;
  final int originalBytes;
  final DateTime createdAt;

  _AssetMeta({
    required this.id,
    required this.originalBytes,
    required this.createdAt,
  });
}
--------------------------------------------------------------------------------

services/foreground_notifier.dart
import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class ForegroundNotifier {
  static Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'compress_progress',
        channelName: 'Compression Progress',
        channelDescription:
            'Shows current folder and progress while compressing',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
        showWhen: true,
        // remove unsupported fields like isSticky, playSound defaults false
        // enableVibration/playSound can stay default false
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      ),
      iosNotificationOptions: IOSNotificationOptions(
        showNotification: true,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // ✅ required in recent versions
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  static Future<void> start(
      {required String title, required String text}) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await FlutterForegroundTask.startService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  static Future<void> update({String? title, String? text}) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await FlutterForegroundTask.stopService();
  }
}
--------------------------------------------------------------------------------

services/storage.dart
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/folder_job.dart';
import '../models/trash_item.dart';

/// Simple JSON file storage to persist state across sessions.
class StorageService {
  static final StorageService _i = StorageService._();
  StorageService._();
  factory StorageService() => _i;

  File? _file;

  Future<File> _ensureFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/jobs_state.json');
    if (!await f.exists()) {
      await f.writeAsString(jsonEncode({
        'jobs': <String, dynamic>{},
        'options': {
          'suffix': '',
          'keepOriginal': false,
          'selectedFolders': <String>[],
        },
        // List of originals that have been compressed and are pending user action.
        'trash': <dynamic>[],
      }));
    }
    _file = f;
    return f;
  }

  Future<Map<String, dynamic>> readAll() async {
    final f = await _ensureFile();
    final s = await f.readAsString();
    return jsonDecode(s) as Map<String, dynamic>;
  }

  Future<void> writeAll(Map<String, dynamic> data) async {
    final f = await _ensureFile();
    await f.writeAsString(const JsonEncoder.withIndent(' ').convert(data));
  }

  Future<Map<String, FolderJob>> loadJobs() async {
    final m = await readAll();
    final raw = (m['jobs'] ?? {}) as Map<String, dynamic>;
    final out = <String, FolderJob>{};
    for (final e in raw.entries) {
      out[e.key] = FolderJob.fromMap(Map<String, dynamic>.from(e.value));
    }
    return out;
  }

  Future<void> saveJobs(Map<String, FolderJob> jobs) async {
    final m = await readAll();
    m['jobs'] = {for (final e in jobs.entries) e.key: e.value.toMap()};
    await writeAll(m);
  }

  Future<Map<String, dynamic>> loadOptions() async {
    final m = await readAll();
    return Map<String, dynamic>.from(m['options'] ?? {});
  }

  Future<void> saveOptions({
    String? suffix,
    bool? keepOriginal,
    List<String>? selectedFolders,
  }) async {
    final m = await readAll();
    final o = Map<String, dynamic>.from(m['options'] ?? {});
    if (suffix != null) o['suffix'] = suffix;
    if (keepOriginal != null) o['keepOriginal'] = keepOriginal;
    if (selectedFolders != null) o['selectedFolders'] = selectedFolders;
    m['options'] = o;
    await writeAll(m);
  }

  // ────────────────────────────────────────────────────────────────────────────
  // "Old files" persistence (trash list)
  // ────────────────────────────────────────────────────────────────────────────

  Future<List<TrashItem>> loadTrash() async {
    final m = await readAll();
    final rawList = (m['trash'] ?? const <dynamic>[]) as List;
    return rawList
        .map((e) => TrashItem.fromMap(
            Map<String, dynamic>.from(e as Map<String, dynamic>)))
        .toList();
  }

  Future<void> saveTrash(List<TrashItem> items) async {
    final m = await readAll();
    m['trash'] = items.map((e) => e.toMap()).toList();
    await writeAll(m);
  }

  /// ✅ NEW: Load trash items and validate that the temp compressed file still exists.
  ///
  /// If the temp file is missing (e.g. app cache cleared / OS eviction),
  /// we prune the entry so we don't block "Start" or tell the user to clear
  /// old files when we can't finalize anything.
  Future<List<TrashItem>> loadTrashValidated({bool persist = true}) async {
    final items = await loadTrash();
    if (items.isEmpty) return items;

    final List<TrashItem> kept = [];
    bool changed = false;

    for (final item in items) {
      bool tempExists = false;
      try {
        tempExists = await File(item.trashedPath).exists();
      } catch (_) {
        tempExists = false;
      }

      if (!tempExists) {
        changed = true;
        continue;
      }

      kept.add(item);
    }

    if (persist && changed) {
      await saveTrash(kept);
    }

    return kept;
  }

  /// Add (or update) an entry representing an original that has been
  /// successfully compressed and is pending deletion/finalization.
  Future<void> addTrashItem(TrashItem item) async {
    final items = await loadTrash();

    // De-duplicate by assetId if available, otherwise by originalPath.
    final idx = items.indexWhere((e) {
      if (item.assetId.isNotEmpty && e.assetId.isNotEmpty) {
        return e.assetId == item.assetId;
      }
      return e.originalPath == item.originalPath;
    });

    if (idx >= 0) {
      items[idx] = item;
    } else {
      items.add(item);
    }

    await saveTrash(items);
  }

  Future<void> clearTrash() async {
    final m = await readAll();
    m['trash'] = <dynamic>[];
    await writeAll(m);
  }
}
--------------------------------------------------------------------------------

services/storage_space_helper.dart
import 'dart:io';

import 'package:flutter/services.dart';

/// Thin wrapper to query free storage space on Android.
///
/// Returns **available bytes** on the main external storage volume.
/// On non-Android platforms, this returns 0 (not used).
class StorageSpaceHelper {
  static const MethodChannel _channel =
      MethodChannel('er_squeeze/storage_space');

  static Future<int> getFreeBytes() async {
    if (!Platform.isAndroid) return 0;

    try {
      final res = await _channel.invokeMethod<int>('getFreeBytes');
      return res ?? 0;
    } on PlatformException {
      return 0;
    }
  }
}
--------------------------------------------------------------------------------

services/trash_helper.dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manages Squeeze's own "trash" area under the app's external files directory.
///
/// On Android this is typically:
///   /storage/emulated/0/Android/data/com.ertelek.squeeze/files/ertelek-squeeze-trash
///
/// We only ever **copy** into this directory now. Deleting the original
/// media entry from the user's gallery is done via MediaStore (photo_manager),
/// not via raw File.delete on public storage.
class TrashHelper {
  static const _trashDirName = 'ertelek-squeeze-trash';

  static Future<Directory> _getTrashDirInternal() async {
    Directory base;

    try {
      // Prefer external app directory so we track space on the same volume
      // as DCIM/Downloads/etc.
      base = (await getExternalStorageDirectory()) ??
          (await getApplicationSupportDirectory());
    } catch (_) {
      base = await getApplicationSupportDirectory();
    }

    final trashDir = Directory(p.join(base.path, _trashDirName));
    if (!await trashDir.exists()) {
      await trashDir.create(recursive: true);
    }
    return trashDir;
  }

  /// Copy [file] into the trash directory, preserving its bytes.
  ///
  /// The original file is **not** touched here; deletion of the user's
  /// media entry is handled via MediaStore APIs in [CompressionManager].
  ///
  /// Returns the final path of the copy in trash, or null if it fails.
  static Future<String?> backupToTrash(File file,
      {String? preferredName}) async {
    try {
      if (!await file.exists()) return null;

      final trashDir = await _getTrashDirInternal();
      final baseName = preferredName?.trim().isNotEmpty == true
          ? preferredName!.trim()
          : p.basename(file.path);

      String safeBase = baseName;
      // Ensure it has some extension; default to .mp4 if none.
      if (p.extension(safeBase).isEmpty) {
        safeBase = '$safeBase.mp4';
      }

      String targetPath = p.join(trashDir.path, safeBase);

      // Avoid collisions
      int counter = 1;
      while (await File(targetPath).exists()) {
        final name = p.basenameWithoutExtension(safeBase);
        final ext = p.extension(safeBase);
        targetPath = p.join(trashDir.path, '$name-$counter$ext');
        counter++;
      }

      final target = File(targetPath);
      await target.writeAsBytes(await file.readAsBytes(), flush: true);
      return target.path;
    } catch (_) {
      return null;
    }
  }

  /// Returns the current trash directory (even if empty).
  static Future<Directory> getTrashDirectory() => _getTrashDirInternal();

  /// True if there is at least one file in the trash directory.
  static Future<bool> hasTrash() async {
    try {
      final dir = await _getTrashDirInternal();
      await for (final e in dir.list(followLinks: false)) {
        if (e is File) return true;
      }
    } catch (_) {
      // ignore
    }
    return false;
  }

  /// Delete all files currently in the trash directory.
  ///
  /// This does not change any MediaStore / gallery entries; those are already
  /// removed when we compressed the originals.
  static Future<void> clearTrashFiles() async {
    try {
      final dir = await _getTrashDirInternal();
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          try {
            await entity.delete();
          } catch (_) {
            // ignore per-file errors
          }
        }
      }
    } catch (_) {
      // ignore
    }
  }
}
--------------------------------------------------------------------------------

services/video_processor.dart
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class VideoProcessor {
  static const String squeezeTag = 'compressed-by:squeeze';

  void _log(String msg) {
    // print(msg);
  }

  String _quote(String s) => '"${s.replaceAll('"', r'\"')}"';

  Future<Directory> _getTempDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'squeeze_encode_tmp'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Returns true if this video was already compressed by Squeeze (metadata marker).
  /// We check multiple common tag fields because containers differ.
  Future<bool> isAlreadyCompressedBySqueeze(File input) async {
    try {
      final session = await FFprobeKit.getMediaInformation(input.path);
      final info = session.getMediaInformation();
      final tags = info?.getTags();
      if (tags == null) return false;

      bool containsTag(dynamic v) {
        final s = v?.toString().toLowerCase();
        return s != null && s.contains(squeezeTag);
      }

      // Common tag keys seen across containers
      if (containsTag(tags['comment'])) return true;
      if (containsTag(tags['description'])) return true;
      if (containsTag(tags['title'])) return true;
      if (containsTag(tags['encoder'])) return true;

      return false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _probeAudioProps(File input) async {
    try {
      final session = await FFprobeKit.getMediaInformation(input.path);
      final info = session.getMediaInformation();
      final streams = info?.getStreams();
      if (streams == null) return {};

      for (final s in streams) {
        if (s.getType() == 'audio') {
          final props = s.getAllProperties() ?? {};
          return {
            'channels': props['channels'],
            'sample_rate': props['sample_rate'],
          };
        }
      }
    } catch (_) {}
    return {};
  }

  String _inputExt(File input) {
    final ext = p.extension(input.path).toLowerCase();
    return ext.isEmpty ? '.mp4' : ext;
  }

  /// Read container/global tags via FFprobe and return a lowercase-keyed map.
  Future<Map<String, String>> _readTags(File input) async {
    try {
      final session = await FFprobeKit.getMediaInformation(input.path);
      final info = session.getMediaInformation();
      final tags = info?.getTags();
      if (tags == null) return const {};

      final out = <String, String>{};
      for (final e in tags.entries) {
        final k = e.key.toString().toLowerCase();
        final v = e.value?.toString();
        if (v != null && v.trim().isNotEmpty) {
          out[k] = v;
        }
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Append [squeezeTag] to an existing tag value without overwriting it.
  /// Avoid duplicates and keep it readable.
  String _appendSqueezeTag(String? existing) {
    final cur = (existing ?? '').trim();

    // Already contains tag -> keep as-is.
    if (cur.toLowerCase().contains(squeezeTag)) return cur;

    // If empty -> just the tag.
    if (cur.isEmpty) return squeezeTag;

    // Choose a separator that tends to survive metadata round-trips.
    // " | " is readable and common.
    return '$cur | $squeezeTag';
  }

  /// Builds -metadata args for multiple fields, preserving existing values
  /// and appending our marker.
  Future<List<String>> _metadataTagArgsPreserve(File input) async {
    final tags = await _readTags(input);

    // FFprobe keys are often lowercase; normalize lookup.
    final existingComment = tags['comment'];
    final existingDescription = tags['description'];
    final existingTitle = tags['title'];
    final existingEncoder = tags['encoder'];

    final commentOut = _appendSqueezeTag(existingComment);
    final descriptionOut = _appendSqueezeTag(existingDescription);
    final titleOut = _appendSqueezeTag(existingTitle);

    return <String>[
      '-metadata',
      'comment=$commentOut',
      '-metadata',
      'description=$descriptionOut',
    ];
  }

  List<String> _buildCmd({
    required File input,
    required String outPath,
    required String ext,
    required int targetCrf,
    required Map<String, dynamic> audioProps,
    required List<String> metadataArgs,
  }) {
    final cmd = <String>[
      '-y',
      '-i',
      _quote(input.path),

      // ✅ Tag outputs so we never re-compress (preserving existing metadata)
      ...metadataArgs,
    ];

    final bool isWebm = ext == '.webm';

    if (isWebm) {
      // WEBM container: VP9 + Opus is the sane default.
      cmd.addAll([
        '-c:v',
        'libvpx-vp9',
        '-crf',
        '27',
        '-b:v',
        '0',
        '-c:a',
        'libopus',
        '-b:a',
        '160k',
      ]);
    } else {
      // Most other containers: H.264 + AAC
      cmd.addAll([
        '-c:v',
        'libx264',
        '-preset',
        'medium',
        '-crf',
        targetCrf.toString(),
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        '-b:a',
        '256k',
      ]);

      if (audioProps['channels'] != null) {
        cmd.addAll(['-ac', audioProps['channels'].toString()]);
      }
      if (audioProps['sample_rate'] != null) {
        cmd.addAll(['-ar', audioProps['sample_rate'].toString()]);
      }

      if (ext == '.mp4' || ext == '.m4v' || ext == '.mov') {
        cmd.addAll(['-movflags', '+faststart']);
      }
    }

    cmd.add(_quote(outPath));
    return cmd;
  }

  Future<({dynamic session, File tempFile, String ext})> encodeToTempSameContainer(
    File input, {
    int targetCrf = 28,
  }) async {
    final tempDir = await _getTempDir();
    final ext = _inputExt(input);
    final base = p.basenameWithoutExtension(input.path);

    final tempPath = p.join(
      tempDir.path,
      '${base}_${DateTime.now().millisecondsSinceEpoch}$ext',
    );

    final audioProps = await _probeAudioProps(input);

    // ✅ Read existing metadata and append to it
    final metadataArgs = await _metadataTagArgsPreserve(input);

    final cmd = _buildCmd(
      input: input,
      outPath: tempPath,
      ext: ext,
      targetCrf: targetCrf,
      audioProps: audioProps,
      metadataArgs: metadataArgs,
    );

    _log('FFmpeg: ${cmd.join(' ')}');
    final session = await FFmpegKit.executeAsync(cmd.join(' '));
    return (session: session, tempFile: File(tempPath), ext: ext);
  }

  Future<bool> isSmallerThanOriginal(File input, File temp) async {
    try {
      return (await temp.length()) < (await input.length());
    } catch (_) {
      return false;
    }
  }

  Future<int> safeLength(File f) async {
    try {
      return await f.length();
    } catch (_) {
      return 0;
    }
  }

  Future<void> discardTemp(File f) async {
    try {
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }
}
--------------------------------------------------------------------------------

