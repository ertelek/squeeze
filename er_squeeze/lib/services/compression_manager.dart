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
            for (int i = 0; i < 3; i++) {
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
