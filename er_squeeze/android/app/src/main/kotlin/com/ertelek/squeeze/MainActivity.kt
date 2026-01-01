package com.ertelek.squeeze

import android.os.Build
import android.os.Environment
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL_STORAGE_SPACE = "er_squeeze/storage_space"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
