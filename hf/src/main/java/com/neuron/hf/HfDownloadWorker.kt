package com.neuron.hf

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.*
import kotlinx.coroutines.CancellationException
import java.io.File
import java.util.UUID

/**
 * Unduhan model di background (WorkManager, foreground dengan notifikasi).
 * Input: repo + daftar file. Progress: file, idx, count, done, total. Output: folder hasil. Error: pesan.
 * Gagal sementara (jaringan) dicoba ulang hingga MAX_ATTEMPTS; unduhan lanjut dari byte terakhir (resume).
 */
class HfDownloadWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {

    companion object {
        const val KEY_REPO = "repo"
        const val KEY_FILES = "files"
        const val KEY_FILE = "file"
        const val KEY_IDX = "idx"
        const val KEY_COUNT = "count"
        const val KEY_DONE = "done"
        const val KEY_TOTAL = "total"
        const val KEY_OUT = "out"
        const val KEY_ERROR = "error"
        private const val CHANNEL = "hf_download"
        private const val NOTIF_ID = 4101
        private const val MAX_ATTEMPTS = 3

        fun uniqueName(repoId: String) = "hf-download-$repoId"

        /** Antrekan unduhan; satu repo hanya satu unduhan aktif (KEEP). */
        fun enqueue(ctx: Context, repoId: String, files: List<String>): UUID {
            val input = Data.Builder()
                .putString(KEY_REPO, repoId)
                .putStringArray(KEY_FILES, files.toTypedArray())
                .build()
            val req = OneTimeWorkRequestBuilder<HfDownloadWorker>()
                .setInputData(input)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(ctx).enqueueUniqueWork(uniqueName(repoId), ExistingWorkPolicy.KEEP, req)
            return req.id
        }
    }

    override suspend fun doWork(): Result {
        val repoId = inputData.getString(KEY_REPO) ?: return Result.failure()
        val files = inputData.getStringArray(KEY_FILES)?.toList() ?: return Result.failure()
        val base = applicationContext.getExternalFilesDir("models") ?: File(applicationContext.filesDir, "models")
        createChannel()
        setForeground(notification(repoId, "Menyiapkan unduhan…", -1))

        var idx = 0
        var count = files.size
        var lastTick = 0L
        fun report(name: String, done: Long, total: Long) {
            setProgressAsync(workDataOf(KEY_FILE to name, KEY_IDX to idx, KEY_COUNT to count, KEY_DONE to done, KEY_TOTAL to total))
            val pct = if (total > 0) (done * 100 / total).toInt() else -1
            setForegroundAsync(notification(repoId, "$idx/$count $name", pct))
        }

        return try {
            val results = HfClient(HfPrefs(applicationContext).token).downloadFiles(
                repoId, files, base,
                onFile = { name, i, n -> idx = i; count = n; report(name, 0L, -1L) },
                onProgress = { name, done, total ->
                    val now = System.currentTimeMillis()
                    if (done == total || now - lastTick > 800) { lastTick = now; report(name, done, total) }
                },
            )
            val failed = results.firstOrNull { !it.ok }
            when {
                failed == null -> Result.success(workDataOf(KEY_OUT to HfClient.targetDir(base, repoId).absolutePath))
                runAttemptCount + 1 < MAX_ATTEMPTS -> Result.retry()
                else -> Result.failure(workDataOf(KEY_ERROR to "${failed.file}: ${failed.error ?: "gagal"}"))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (runAttemptCount + 1 < MAX_ATTEMPTS) Result.retry()
            else Result.failure(workDataOf(KEY_ERROR to (e.message ?: "gagal")))
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = applicationContext.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Unduhan model", NotificationManager.IMPORTANCE_LOW))
        }
    }

    private fun notification(repoId: String, text: String, percent: Int): ForegroundInfo {
        val n = NotificationCompat.Builder(applicationContext, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Unduh: $repoId")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, percent.coerceAtLeast(0), percent < 0)
            .build()
        return if (Build.VERSION.SDK_INT >= 29)
            ForegroundInfo(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else ForegroundInfo(NOTIF_ID, n)
    }
}
