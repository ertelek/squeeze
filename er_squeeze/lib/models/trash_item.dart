class TrashItem {
  /// Filesystem path of the original media file.
  final String originalPath;

  /// Filesystem path of the compressed temp file that should replace
  /// [originalPath] once the user confirms deletion.
  final String trashedPath;

  /// Original size in bytes (before compression).
  final int bytes;

  /// When this item was added to the "old files" list.
  final DateTime trashedAt;

  /// MediaStore / photo_manager asset id for the original.
  ///
  /// This is used so we can call PhotoManager.editor.deleteWithIds(...)
  /// once, in a batch, after all compression has completed.
  final String assetId;

  const TrashItem({
    required this.originalPath,
    required this.trashedPath,
    required this.bytes,
    required this.trashedAt,
    required this.assetId,
  });

  Map<String, dynamic> toMap() => {
        'originalPath': originalPath,
        'trashedPath': trashedPath,
        'bytes': bytes,
        'trashedAt': trashedAt.toIso8601String(),
        'assetId': assetId,
      };

  static TrashItem fromMap(Map<String, dynamic> m) => TrashItem(
        originalPath: (m['originalPath'] ?? '') as String,
        trashedPath: (m['trashedPath'] ?? '') as String,
        bytes: (m['bytes'] ?? 0) as int,
        trashedAt: DateTime.tryParse(m['trashedAt'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        assetId: (m['assetId'] ?? '') as String,
      );
}
