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
  int _oldBytes = 0;
  int _freeBytes = 0;

  // ✅ NEW: initial loading gate
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

  /// Load "old files" statistics (pending originals) + free space.
  Future<void> _loadOldFilesStats() async {
    int count = 0;
    int bytes = 0;

    try {
      final List<TrashItem> items = await _storage.loadTrash();
      count = items.length;
      for (final item in items) {
        bytes += item.bytes;
      }
    } catch (_) {
      count = 0;
      bytes = 0;
    }

    final free = await StorageSpaceHelper.getFreeBytes();

    _oldCount = count;
    _oldBytes = bytes;
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

  /// Top card: always show free space on the device.
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
            const SizedBox(height: 4),
            Text(
              hasOldFiles
                  ? 'There ${_oldCount == 1 ? 'is' : 'are'} $_oldCount old '
                      '${_oldCount == 1 ? 'video' : 'videos'} that can now be deleted '
                      '(${_formatBytes(_oldBytes)}).\n\n'
                      'Clearing old files will permanently delete the original '
                      'versions and keep the compressed versions in their place.'
                  : 'After compressing, your old files will appear here '
                      'so you can delete them and free up space.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
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
        appBar: AppBar(title: Text('Status')),
        body: Center(child: CircularProgressIndicator()),
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
              final name = job.displayName;
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
                  title: Text(name),
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
            }).toList(),
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
