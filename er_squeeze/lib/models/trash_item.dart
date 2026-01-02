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
