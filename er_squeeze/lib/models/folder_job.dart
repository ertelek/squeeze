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
