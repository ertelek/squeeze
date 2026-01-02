package com.ertelek.squeeze

import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL_STORAGE_SPACE = "er_squeeze/storage_space"
    private val CHANNEL_MEDIA_SCANNER = "er_squeeze/media_scanner"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Existing: free storage bytes
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_STORAGE_SPACE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getFreeBytes" -> {
                        try {
                            val freeBytes = getAvailableBytes()
                            result.success(freeBytes)
                        } catch (e: Exception) {
                            result.error("ERR_STORAGE", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // NEW: media scanner (so Gallery indexes newly written files)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_MEDIA_SCANNER)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanFile" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "Missing 'path'", null)
                            return@setMethodCallHandler
                        }

                        try {
                            MediaScannerConnection.scanFile(
                                this,
                                arrayOf(path),
                                null
                            ) { _, _ ->
                                // Best-effort; no async result needed.
                            }
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("scan_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Returns available bytes on the primary external storage volume
     * (same physical storage where DCIM/Pictures live).
     */
    private fun getAvailableBytes(): Long {
        val storageDir = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // On scoped storage devices, still points to the primary shared storage.
            Environment.getExternalStorageDirectory()
        } else {
            Environment.getExternalStorageDirectory()
        }

        val stat = StatFs(storageDir.absolutePath)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
            stat.availableBytes
        } else {
            @Suppress("DEPRECATION")
            stat.availableBlocks.toLong() * stat.blockSize.toLong()
        }
    }
}
