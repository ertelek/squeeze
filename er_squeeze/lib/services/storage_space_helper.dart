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
