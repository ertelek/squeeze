import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
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

  // MediaScanner channel (Android only)
  static const MethodChannel _mediaScannerChannel =
      MethodChannel('er_squeeze/media_scanner');

  bool _isRunningFlag = false;
  bool _isPausedFlag = false;
  int? _activeFfmpegSessionId;
  Completer<void>? _stopBarrier;

  // Track current encode so pause/stop can clean up correctly.
  File? _activeTempFile;
  String? _activeAssetId; // informational + debugging (and future use)

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

  /// (directory-based core):
  /// Try writing the bundled test video into [albumDir] using the same
  /// “copy bytes to destination path + media scan” approach used when
  /// finalizing replacements, then delete it.
  ///
  /// Returns true if the test file existed at the destination after writing.
  Future<bool> canAccessAlbumDirectory(String albumDir) async {
    final String filename =
        'squeeze_album_access_test_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final String destPath = p.join(albumDir, filename);

    File? tmp;
    bool exists = false;

    try {
      final bytes =
          (await rootBundle.load('assets/in-app/test-album-access.mp4'))
              .buffer
              .asUint8List();

      final tempDir = await getTemporaryDirectory();
      tmp = File(
        p.join(
          tempDir.path,
          'test-album-access_${DateTime.now().millisecondsSinceEpoch}.mp4',
        ),
      );
      await tmp.writeAsBytes(bytes, flush: true);

      // Same semantics as finalize replacement: copy temp bytes to target path
      await tmp.copy(destPath);

      // Media scan so Gallery/MediaStore can see it (best-effort)
      await _scanFileIfAndroid(destPath);

      // Small delay can help MediaScanner settle, but not strictly required for exists()
      await Future<void>.delayed(const Duration(milliseconds: 1000));

      exists = await File(destPath).exists();
    } catch (_) {
      exists = false;
    } finally {
      // Always try to delete the test file (best effort).
      try {
        final f = File(destPath);
        if (await f.exists()) {
          await f.delete();
          await _scanFileIfAndroid(destPath);
        }
      } catch (_) {}

      // Clean up temp
      if (tmp != null) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
    }

    return exists;
  }

  /// (album-based wrapper):
  /// Determine album directory by peeking at one asset file, then call
  /// [canAccessAlbumDirectory]. If we can’t determine a dir (e.g. empty),
  /// we return true so we don’t incorrectly mark albums inaccessible.
  Future<bool> canAccessAlbum(AssetPathEntity album) async {
    String? albumDir;
    try {
      final total = await album.assetCountAsync;
      if (total <= 0) return true;

      final assets = await album.getAssetListRange(start: 0, end: 1);
      if (assets.isEmpty) return true;

      final f = await assets.first.file;
      if (f == null) return true;

      albumDir = Directory(f.parent.path).path;
    } catch (_) {
      return true;
    }

    return canAccessAlbumDirectory(albumDir);
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

    // If LIMITED access, do not start.
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
    final allPaths =
        await PhotoManager.getAssetPathList(type: RequestType.video);
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

        // storage warning
        await _checkStorageAndWarnIfLow(jobs);

        final file = await asset.file;
        if (file == null) {
          _log('Asset file is null for id=${asset.id}, skipping.');
          _markAssetDone(job, asset.id, 0);
          await _storage.saveJobs(jobs);
          continue;
        }

        // Skip if already tagged as Squeeze output
        final alreadyTagged =
            await videoProcessor.isAlreadyCompressedBySqueeze(file);
        if (alreadyTagged) {
          final originalSize = await videoProcessor.safeLength(file);
          _markAssetDone(job, asset.id, originalSize);
          await _storage.saveJobs(jobs);
          continue;
        }

        // Encode to app-private temp file, preserving container/extension
        final handle = await videoProcessor.encodeToTempSameContainer(
          file,
          targetCrf: 23,
        );

        // Track active session + temp file so pause can clean it up.
        _activeFfmpegSessionId = await handle.session.getSessionId();
        _activeTempFile = handle.tempFile;
        _activeAssetId = asset.id;

        // Wait until success/fail/cancel OR pause/stop triggers cancel.
        while (true) {
          if (!_isRunningFlag || _isPausedFlag) {
            final id = _activeFfmpegSessionId;
            if (id != null) {
              try {
                await FFmpegKit.cancel(id);
              } catch (_) {}
            }
            break;
          }
          final rc = await handle.session.getReturnCode();
          if (rc != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }

        final rc = await handle.session.getReturnCode();

        // If we paused/stopped (or got a cancel return code), cleanup and DO NOT
        // mark the asset completed.
        final bool interrupted =
            !_isRunningFlag || _isPausedFlag || (rc != null && rc.isValueCancel());

        if (interrupted) {
          await videoProcessor.discardTemp(handle.tempFile);

          _activeFfmpegSessionId = null;
          _activeTempFile = null;
          _activeAssetId = null;

          if (!_isRunningFlag) break;
          continue;
        }

        if (rc != null && rc.isValueSuccess()) {
          final originalSize = await videoProcessor.safeLength(file);
          final compressedSize = await videoProcessor.safeLength(handle.tempFile);

          final smaller =
              await videoProcessor.isSmallerThanOriginal(file, handle.tempFile);
          if (!smaller) {
            await videoProcessor.discardTemp(handle.tempFile);
            _markAssetDone(job, asset.id, originalSize);
            await _storage.saveJobs(jobs);

            _activeFfmpegSessionId = null;
            _activeTempFile = null;
            _activeAssetId = null;
            continue;
          }

          if (!keepOriginal) {
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
            final srcExt = handle.ext;
            final stem = p.basenameWithoutExtension(file.path);
            final safeSuffix =
                suffix.trim().isEmpty ? '_compressed' : suffix.trim();
            final outPath = p.join(file.parent.path, '$stem$safeSuffix$srcExt');

            var finalOut = outPath;
            int counter = 1;
            while (await File(finalOut).exists()) {
              finalOut =
                  p.join(file.parent.path, '$stem$safeSuffix-$counter$srcExt');
              counter++;
            }

            await handle.tempFile.copy(finalOut);
            await videoProcessor.discardTemp(handle.tempFile);

            await _scanFileIfAndroid(finalOut);

            job.compressedPaths.add(finalOut);
          }

          _markAssetDone(job, asset.id, originalSize);
          await _storage.saveJobs(jobs);

          await ForegroundNotifier.update(
            title: 'Squeezing ${_composeDisplayTitle(job)}',
            text: keepOriginal ? '' : _buildNotificationText(job),
          );

          _activeFfmpegSessionId = null;
          _activeTempFile = null;
          _activeAssetId = null;

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

          _activeFfmpegSessionId = null;
          _activeTempFile = null;
          _activeAssetId = null;

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

    final id = _activeFfmpegSessionId;
    if (id != null) {
      try {
        await FFmpegKit.cancel(id);
      } catch (_) {}
    }

    final tmp = _activeTempFile;
    if (tmp != null) {
      try {
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (_) {}
    }

    _activeFfmpegSessionId = null;
    _activeTempFile = null;
    _activeAssetId = null;

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

  Future<void> stopAndWait({Duration timeout = const Duration(seconds: 5)}) async {
    _isRunningFlag = false;
    _isPausedFlag = false;
    _log('STOP requested');

    final id = _activeFfmpegSessionId;
    if (id != null) {
      try {
        await FFmpegKit.cancel(id);
      } catch (_) {}
    }

    final tmp = _activeTempFile;
    if (tmp != null) {
      try {
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (_) {}
    }

    _activeFfmpegSessionId = null;
    _activeTempFile = null;
    _activeAssetId = null;

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
  /// Updated behavior:
  /// - Process albums one-by-one (grouped by originalPath parent directory).
  /// - Before deleting originals for a group, verify that the album directory is accessible
  ///   using [canAccessAlbumDirectory] (same test-write mechanism).
  /// - If inaccessible:
  ///     • do NOT delete originals in that album dir
  ///     • show a popup (toast) to the user
  ///     • delete ONLY the compressed temp versions for that album dir
  ///     • move on to the next album dir
  Future<void> clearOldFiles() async {
    final items = await _storage.loadTrashValidated();
    if (items.isEmpty) return;

    // Group by album directory (derived from the *originalPath* we’re replacing).
    final Map<String, List<TrashItem>> byDir = {};
    for (final item in items) {
      String dir;
      try {
        dir = File(item.originalPath).parent.path;
      } catch (_) {
        dir = '__unknown__';
      }
      byDir.putIfAbsent(dir, () => <TrashItem>[]).add(item);
    }

    final List<TrashItem> stillPending = [];

    for (final entry in byDir.entries) {
      final albumDir = entry.key;
      final groupItems = entry.value;

      // Unknown directory -> keep pending (we can’t safely decide).
      if (albumDir == '__unknown__') {
        stillPending.addAll(groupItems);
        continue;
      }

      final albumName = p.basename(albumDir).isEmpty ? albumDir : p.basename(albumDir);

      final accessible = await canAccessAlbumDirectory(albumDir);

      if (!accessible) {
        _toast(
          'Squeeze! was unable to access the album "$albumName". '
          'Move the videos from that album to a different album and try again.',
        );

        // Delete compressed versions for THIS album dir only, keep originals.
        for (final item in groupItems) {
          try {
            final tf = File(item.trashedPath);
            if (await tf.exists()) {
              await tf.delete();
            }
          } catch (_) {}
          // Do not keep pending (compressed copies removed).
        }

        continue; // move to next album dir
      }

      // Album dir accessible -> delete originals for this group.
      final ids = groupItems
          .map((e) => e.assetId.trim())
          .where((id) => id.isNotEmpty)
          .toList();

      bool deleteCallFailed = false;
      if (ids.isNotEmpty) {
        try {
          await PhotoManager.editor.deleteWithIds(ids);
        } catch (e) {
          deleteCallFailed = true;
          _log('Failed to delete originals via MediaStore for "$albumName": $e');
          _toast('Could not delete old videos in "$albumName". Please try again.');
        }
      }

      for (final item in groupItems) {
        final tempFile = File(item.trashedPath);

        final tempExists = await _safeExists(tempFile);
        if (!tempExists) {
          continue;
        }

        if (deleteCallFailed) {
          stillPending.add(item);
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
    }

    await _storage.saveTrash(stillPending);
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

      await _scanFileIfAndroid(originalPath);

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

  Future<void> _scanFileIfAndroid(String path) async {
    if (!Platform.isAndroid) return;
    try {
      await _mediaScannerChannel.invokeMethod<void>('scanFile', {'path': path});
    } catch (e) {
      _log('Media scan failed for $path: $e');
    }
  }

  void _log(String message) {
    // ignore: avoid_print
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
    _activeTempFile = null;
    _activeAssetId = null;

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
        final assets =
            await pathEntity.getAssetListRange(start: start, end: end);
        for (final asset in assets) {
          if (asset.type != AssetType.video) continue;

          int sizeBytes = 0;
          try {
            final f = await asset.file;
            if (f != null) sizeBytes = await f.length();
          } catch (_) {
            sizeBytes = 0;
          }

          metas.add(_AssetMeta(
            id: asset.id,
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
