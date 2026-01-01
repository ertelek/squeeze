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
