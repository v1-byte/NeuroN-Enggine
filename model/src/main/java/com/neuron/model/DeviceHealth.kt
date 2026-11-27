package com.neuron.model

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.StatFs

/** Snapshot kemampuan perangkat yang dipakai sebelum model lokal diaktifkan. */
data class DeviceHealth(
    val totalRamBytes: Long,
    val availableRamBytes: Long,
    val freeStorageBytes: Long,
    val cpuCores: Int,
    val abi: String,
    val sdk: Int,
    val lowRamDevice: Boolean,
    val modelSizeBytes: Long,
    val recommendedMaxModelBytes: Long,
    val warnings: List<String>,
) {
    companion object {
        fun inspect(context: Context, modelSizeBytes: Long = 0L): DeviceHealth {
            val activity = context.getSystemService(ActivityManager::class.java)
            val memory = ActivityManager.MemoryInfo().also { activity?.getMemoryInfo(it) }
            val storage = StatFs(context.getExternalFilesDir(null)?.path ?: context.filesDir.path)
            val free = storage.availableBytes
            val available = memory.availMem
            // Model mmap + runtime membutuhkan headroom; jangan rekomendasikan seluruh RAM bebas.
            val maxModel = (available * 0.70).toLong().coerceAtLeast(0L)
            val warnings = buildList {
                if (modelSizeBytes > 0L && modelSizeBytes > maxModel) {
                    add("Model lebih besar dari rekomendasi RAM bebas (${format(modelSizeBytes)} vs ${format(maxModel)}).")
                }
                if (modelSizeBytes > 0L && modelSizeBytes > free) {
                    add("Ruang penyimpanan tidak cukup untuk model (${format(modelSizeBytes)} dibutuhkan, ${format(free)} tersedia).")
                }
                if (memory.lowMemory) add("Android sedang menandai perangkat dalam kondisi low-memory.")
                if (Build.SUPPORTED_ABIS.none { it == "arm64-v8a" }) {
                    add("ABI arm64-v8a tidak tersedia; native llama.cpp mungkin tidak kompatibel.")
                }
            }
            return DeviceHealth(
                totalRamBytes = memory.totalMem,
                availableRamBytes = available,
                freeStorageBytes = free,
                cpuCores = Runtime.getRuntime().availableProcessors(),
                abi = Build.SUPPORTED_ABIS.joinToString(", "),
                sdk = Build.VERSION.SDK_INT,
                lowRamDevice = activity?.isLowRamDevice == true,
                modelSizeBytes = modelSizeBytes,
                recommendedMaxModelBytes = maxModel,
                warnings = warnings,
            )
        }

        private fun format(bytes: Long): String = when {
            bytes >= 1_000_000_000L -> "%.1f GB".format(bytes / 1_000_000_000.0)
            else -> "%.0f MB".format(bytes / 1_000_000.0)
        }
    }
}
