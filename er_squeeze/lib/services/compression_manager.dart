import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:fluttertoast/fluttertoast.dart';
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
        return false; // found another asset still pending
      }
    }
    return true; // this was the last one
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

    // Ensure media permission (MediaStore).
    final ps = await PhotoManager.requestPermissionExtend();
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

      // Main file-processing loop
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

        // Label current file in UI (just the title/filename).
        job.currentFilePath = asset.title ?? 'Video';
        await _storage.saveJobs(jobs);
        await ForegroundNotifier.update(
          title: 'Squeezing ${_composeDisplayTitle(job)}',
          text: keepOriginal ? '' : _buildNotificationText(job),
        );

        // Storage-space check before each compression step.
        await _checkStorageAndWarnIfLow(jobs);

        final file = await asset.file;
        if (file == null) {
          _log('Asset file is null for id=${asset.id}, skipping.');
          // Mark as done with size 0 to avoid infinite loops.
          job.completedSizes[asset.id] = job.completedSizes[asset.id] ?? 0;
          job.fileIndex[asset.id] = FileState(
            originalBytes:
                job.fileIndex[asset.id]?.originalBytes ?? 0, // keep old size
            compressed: true,
          );
          job.totalBytes = job.mappedTotalBytes;
          job.processedBytes = job.mappedCompressedBytes;
          await _storage.saveJobs(jobs);
          continue;
        }

        final videoProcessor = VideoProcessor();

        final handle = await videoProcessor.reencodeH264AacAsync(
          file,
          outputDirPath: file.parent.path,
          labelSuffix: suffix,
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
          final originalSize = await _tryGetFileSize(file);

          // Progress accounting.
          job.completedSizes[asset.id] = originalSize;
          final prev = job.fileIndex[asset.id];
          job.fileIndex[asset.id] = FileState(
            originalBytes: prev?.originalBytes ?? originalSize,
            compressed: true,
          );
          job.totalBytes = job.mappedTotalBytes;
          job.processedBytes = job.mappedCompressedBytes;

          // 2) If output grew, replace it with the original bytes.
          await _ensureOutputNoBiggerThanInput(
            input: file,
            outputPath: handle.outPath,
            inputSize: originalSize,
          );

          final compressedFile = File(handle.outPath);

          if (suffix.trim().isEmpty && !keepOriginal) {
            // In-place semantics, but we postpone the destructive delete
            // until the user taps "Clear old files" in the UI.
            //
            // Here we only record:
            //  - original path (where the final file should live),
            //  - temp compressed path,
            //  - bytes & assetId.
            final item = TrashItem(
              originalPath: file.path,
              trashedPath: compressedFile.path,
              bytes: originalSize,
              trashedAt: DateTime.now(),
              assetId: asset.id,
            );
            await _storage.addTrashItem(item);

            // For bookkeeping, record that we have a compressed representation.
            job.compressedPaths.add(compressedFile.path);
          } else {
            // Suffix mode or explicit "keep originals": keep compressed file
            // as a separate path on disk and do NOT schedule any deletion.
            job.compressedPaths.add(handle.outPath);
          }

          await _storage.saveJobs(jobs);
          _log('Finished: asset=${asset.id} (${job.currentFilePath})');

          await ForegroundNotifier.update(
            title: 'Squeezing ${_composeDisplayTitle(job)}',
            text: keepOriginal ? '' : _buildNotificationText(job),
          );
          await _storage.saveJobs(jobs);

          // Gentle pacing — skip if this was the last asset.
          final isLast = _isLastAssetInJob(job, asset.id);

          if (!isLast) {
            for (int i = 0; i < 3; i++) {
              if (!_isRunningFlag || _isPausedFlag) break;
              await Future<void>.delayed(const Duration(seconds: 1));
            }
          }
        } else {
          // Error: record logs and mark asset to avoid infinite loop.
          try {
            final allLogs = await handle.session.getAllLogs();
            final output = allLogs.map((e) => e.getMessage()).join('\n');
            job.errorMessage = output;
          } catch (e) {
            job.errorMessage = e.toString();
          }
          await _storage.saveJobs(jobs);

          if (_isPausedFlag) {
            while (_isPausedFlag && _isRunningFlag) {
              await Future<void>.delayed(const Duration(milliseconds: 300));
            }
          } else if (!_isRunningFlag) {
            break;
          } else {
            job.completedSizes[asset.id] = job.completedSizes[asset.id] ?? 0;
            final prev = job.fileIndex[asset.id];
            job.fileIndex[asset.id] = FileState(
              originalBytes: prev?.originalBytes ?? 0,
              compressed: true,
            );
            job.totalBytes = job.mappedTotalBytes;
            job.processedBytes = job.mappedCompressedBytes;
            await _storage.saveJobs(jobs);
          }
        }
      }
    }

    await _finish();
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
  /// IMPORTANT:
  /// - We only remove references from our "trash" list once we are sure:
  ///   (1) the original was actually deleted from MediaStore/FS, AND
  ///   (2) we successfully copied the compressed temp into the original path.
  ///
  /// This prevents "user denied deletion" from accidentally wiping our tracking.
  Future<void> clearOldFiles() async {
    final items = await _storage.loadTrash();
    if (items.isEmpty) return;

    // 1) Ask Android/MediaStore to delete originals (user may deny).
    final ids = items
        .map((e) => e.assetId.trim())
        .where((id) => id.isNotEmpty)
        .toList();

    bool deleteCallFailed = false;
    if (ids.isNotEmpty) {
      try {
        // NOTE: Some PhotoManager versions return bool; others throw on failure.
        // We treat "no throw" as "request issued", but we still verify afterwards.
        await PhotoManager.editor.deleteWithIds(ids);
      } catch (e) {
        deleteCallFailed = true;
        _log('Failed to delete originals via MediaStore: $e');
        _toast(
          'Could not request deletion of old originals. Please try again.',
        );
      }
    }

    // 2) Verify per-item, and only then finalize replacement + remove from trash.
    final List<TrashItem> stillPending = [];

    for (final item in items) {
      final tempFile = File(item.trashedPath);
      final originalFile = File(item.originalPath);

      final tempExists = await _safeExists(tempFile);
      final originalExists = await _safeExists(originalFile);

      // If the temp file is missing, we cannot finalize.
      // In this case, we should NOT block the user forever. We prune safely:
      // - If original still exists: nothing to clear/replace anymore -> drop entry.
      // - If original is gone too: we can't restore -> drop entry, but warn.
      if (!tempExists) {
        if (originalExists) {
          _log(
            'Trash item has no temp file but original exists; pruning entry. '
            'original=${item.originalPath}',
          );
          _toast(
            'An old-file entry was removed because its compressed temp file is missing.',
          );
          continue;
        } else {
          _log(
            'Trash item has no temp file and original missing; pruning entry. '
            'original=${item.originalPath}',
          );
          _toast(
            'An old-file entry was removed because both original and temp files are missing.',
          );
          continue;
        }
      }

      // If original still exists, user likely denied deletion (or MediaStore failed).
      // We verify via:
      // - AssetEntity.fromId (if assetId present)
      // - and filesystem existence as a fallback.
      final deleted = await _isOriginalDefinitelyDeleted(item);

      if (!deleted) {
        // Keep tracking; do NOT copy over existing original.
        stillPending.add(item);
        continue;
      }

      // 3) Original is truly gone -> finalize: put compressed bytes into originalPath.
      final ok = await _finalizeReplacement(
        tempFile: tempFile,
        originalPath: item.originalPath,
      );

      if (!ok) {
        // If we couldn't finalize, keep the item so user can retry.
        stillPending.add(item);
        continue;
      }

      // If finalize succeeded, we drop it from trash by NOT adding to stillPending.
    }

    // 4) Persist the remaining items. (Never blanket-clear unless all truly handled.)
    await _storage.saveTrash(stillPending);

    // If the delete request failed entirely, keep items (already done), but don't
    // confuse the user. (The toast above already explains.)
    if (deleteCallFailed) return;
  }

  Future<bool> _safeExists(File f) async {
    try {
      return await f.exists();
    } catch (_) {
      return false;
    }
  }

  /// Returns true only when we're confident the original is gone.
  ///
  /// - If assetId is available: we treat `AssetEntity.fromId == null` as deleted.
  /// - Also uses filesystem existence of originalPath as a backup signal.
  Future<bool> _isOriginalDefinitelyDeleted(TrashItem item) async {
    bool assetGone = false;
    bool pathGone = false;

    // MediaStore verification (best signal)
    final id = item.assetId.trim();
    if (id.isNotEmpty) {
      try {
        final ent = await AssetEntity.fromId(id);
        assetGone = (ent == null);
      } catch (_) {
        // If we can't query, fall back to filesystem check.
        assetGone = false;
      }
    }

    // Filesystem verification (fallback / additional)
    try {
      pathGone = !(await File(item.originalPath).exists());
    } catch (_) {
      pathGone = false;
    }

    // If we have an assetId, prefer that signal, but also accept pathGone.
    if (id.isNotEmpty) return assetGone || pathGone;

    // If no assetId, we can only trust the filesystem check.
    return pathGone;
  }

  /// Copy the temp compressed file into originalPath, then delete temp.
  /// Returns true only if everything succeeded.
  Future<bool> _finalizeReplacement({
    required File tempFile,
    required String originalPath,
  }) async {
    try {
      // Ensure destination directory exists
      final parent = Directory(File(originalPath).parent.path);
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }

      // Copy temp into original path
      await tempFile.copy(originalPath);

      // Remove temp
      try {
        await tempFile.delete();
      } catch (_) {
        // Non-fatal, but we’d prefer to keep disk clean.
      }

      return true;
    } catch (e) {
      _log('Failed to finalize replacement to $originalPath: $e');
      _toast('Failed to finalize a compressed file. Please try again.');
      return false;
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Internal helpers
  // ────────────────────────────────────────────────────────────────────────────

  void _log(String message) {
    // print(message);
  }

  void _toast(String msg) {
    Fluttertoast.showToast(msg: msg, toastLength: Toast.LENGTH_LONG);
  }

  String _composeDisplayTitle(FolderJob job) {
    return job.displayName;
  }

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

  Future<int> _tryGetFileSize(File f) async {
    try {
      return await f.length();
    } catch (_) {
      return 0;
    }
  }

  /// If the compressed output is larger than the original, overwrite the
  /// output with the original bytes so the user never ends up with bigger
  /// "compressed" files.
  Future<void> _ensureOutputNoBiggerThanInput({
    required File input,
    required String outputPath,
    required int inputSize,
  }) async {
    try {
      final outFile = File(outputPath);
      if (!await outFile.exists()) {
        _log('Output file missing when comparing sizes: $outputPath');
        return;
      }
      final outSize = await outFile.length();
      if (outSize > inputSize) {
        _log(
          'Output larger than input ($outSize > $inputSize). '
          'Replacing output with original bytes.',
        );
        await outFile.writeAsBytes(await input.readAsBytes(), flush: true);
      }
    } catch (e) {
      _log('Size compare/overwrite failed for $outputPath: $e');
    }
  }

  /// Index all video assets for [pathEntity] into [job.fileIndex], in
  /// **chronological order (oldest → newest)** so that compressed replacements
  /// preserve the original age ordering as much as possible.
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

          final createdAt = asset.createDateTime;
          metas.add(_AssetMeta(
            id: id,
            originalBytes: sizeBytes,
            createdAt: createdAt,
          ));
        }
      }
    } catch (e) {
      _log('Error indexing assets for album ${job.displayName}: $e');
    }

    // Sort by creation date ascending: oldest → newest.
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

  /// Find the next uncompressed video asset (by id) for this job,
  /// iterating in the order established by [_indexAssetsForJob]
  /// (oldest → newest).
  Future<AssetEntity?> _findNextAssetForJob(FolderJob job) async {
    for (final entry in job.fileIndex.entries) {
      final id = entry.key;
      final fs = entry.value;
      if (fs.compressed) continue;

      final asset = await AssetEntity.fromId(id);
      if (asset == null) {
        // Asset was removed; mark as completed and skip.
        job.completedSizes[id] = job.completedSizes[id] ?? fs.originalBytes;
        job.fileIndex[id] = FileState(
          originalBytes: fs.originalBytes,
          compressed: true,
        );
        job.totalBytes = job.mappedTotalBytes;
        job.processedBytes = job.mappedCompressedBytes;
        await _storage.saveJobs(await _storage.loadJobs());
        continue;
      }
      if (asset.type != AssetType.video) {
        job.completedSizes[id] = job.completedSizes[id] ?? fs.originalBytes;
        job.fileIndex[id] = FileState(
          originalBytes: fs.originalBytes,
          compressed: true,
        );
        job.totalBytes = job.mappedTotalBytes;
        job.processedBytes = job.mappedCompressedBytes;
        await _storage.saveJobs(await _storage.loadJobs());
        continue;
      }
      return asset;
    }
    return null;
  }

  /// Compute total bytes left to compress across all jobs.
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

  /// Warn user if free space is < 2x bytes left AND there are originals
  /// that have already been compressed but not yet cleared by the user.
  Future<void> _checkStorageAndWarnIfLow(Map<String, FolderJob> jobs) async {
    if (!Platform.isAndroid) return;

    final freeBytes = await StorageSpaceHelper.getFreeBytes();
    final bytesLeft = _bytesLeftAcrossJobs(jobs);
    final hasPendingOldFiles = (await _storage.loadTrash()).isNotEmpty;

    if (bytesLeft <= 0 || !hasPendingOldFiles) return;

    if (freeBytes < bytesLeft * 2) {
      _toast(
        'Storage is getting low. Open Squeeze and clear old files.',
      );
      await ForegroundNotifier.update(
        text: 'Low storage: open Squeeze and clear old files',
      );
      for (int i = 0; i < 60 * (bytesLeft * 2 / freeBytes); i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> _finish() async {
    try {
      final pending = await _storage.loadTrash();
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
    } catch (_) {
      // ignore
    }

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
