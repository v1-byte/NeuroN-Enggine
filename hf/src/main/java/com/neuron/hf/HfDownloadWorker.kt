package com.neuron.hf

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.*
import kotlinx.coroutines.CancellationException
import org.json.JSONArray
import org.json.JSONObject
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
        const val KEY_SPEED = "speed"
        const val KEY_ETA = "eta"
        const val KEY_OUT = "out"
        const val KEY_MODEL = "model"
        const val KEY_ERROR = "error"
        private const val CHANNEL = "hf_download"
        private const val NOTIF_ID = 4101
        private const val MAX_ATTEMPTS = 3
        private const val REQUESTS = "hf_download_requests"
        private const val HISTORY = "hf_download_history"

        fun uniqueName(repoId: String) = "hf-download-$repoId"

        /** Antrekan unduhan; satu repo/file hanya satu unduhan aktif. */
        fun enqueue(ctx: Context, repoId: String, files: List<String>): UUID {
            val input = Data.Builder()
                .putString(KEY_REPO, repoId)
                .putStringArray(KEY_FILES, files.toTypedArray())
                .build()
            val req = OneTimeWorkRequestBuilder<HfDownloadWorker>()
                .setInputData(input)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(ctx).enqueueUniqueWork(uniqueName(repoId), ExistingWorkPolicy.REPLACE, req)
            ctx.getSharedPreferences(REQUESTS, Context.MODE_PRIVATE).edit()
                .putString(req.id.toString(), "$repoId\n${files.joinToString("\u0000")}").apply()
            updateHistory(ctx, req.id, repoId, files.firstOrNull().orEmpty(), "queued")
            return req.id
        }

        fun pause(ctx: Context, id: UUID): Boolean {
            val info = WorkManager.getInstance(ctx).getWorkInfoById(id).get() ?: return false
            WorkManager.getInstance(ctx).cancelWorkById(id)
            updateHistory(ctx, id, state = "paused")
            return info.state != WorkInfo.State.SUCCEEDED
        }

        fun resume(ctx: Context, id: UUID): UUID? {
            val raw = ctx.getSharedPreferences(REQUESTS, Context.MODE_PRIVATE).getString(id.toString(), null) ?: return null
            val split = raw.split("\n", limit = 2)
            if (split.size != 2) return null
            val files = split[1].split('\u0000').filter { it.isNotBlank() }
            return enqueue(ctx, split[0], files)
        }

        fun forget(ctx: Context, id: UUID) {
            ctx.getSharedPreferences(REQUESTS, Context.MODE_PRIVATE).edit().remove(id.toString()).apply()
        }

        fun history(ctx: Context): List<Map<String, Any?>> {
            val json = runCatching { JSONObject(ctx.getSharedPreferences(HISTORY, Context.MODE_PRIVATE).getString("items", "{}")) }.getOrElse { JSONObject() }
            return json.keys().asSequence().mapNotNull { key ->
                json.optJSONObject(key)?.let { item ->
                    mapOf("id" to key, "repo" to item.optString("repo"), "file" to item.optString("file"), "state" to item.optString("state"), "startedAt" to item.optLong("startedAt"), "finishedAt" to item.optLong("finishedAt"), "error" to item.optString("error"))
                }
            }.sortedByDescending { it["startedAt"] as Long }.take(30).toList()
        }

        private fun updateHistory(ctx: Context, id: UUID, repo: String? = null, file: String? = null, state: String, error: String = "") {
            val prefs = ctx.getSharedPreferences(HISTORY, Context.MODE_PRIVATE)
            val json = runCatching { JSONObject(prefs.getString("items", "{}")) }.getOrElse { JSONObject() }
            val item = json.optJSONObject(id.toString()) ?: JSONObject()
            if (!repo.isNullOrBlank()) item.put("repo", repo)
            if (!file.isNullOrBlank()) item.put("file", file)
            item.put("state", state)
            if (!item.has("startedAt")) item.put("startedAt", System.currentTimeMillis())
            if (state in setOf("succeeded", "failed", "cancelled")) item.put("finishedAt", System.currentTimeMillis())
            if (error.isNotBlank()) item.put("error", error)
            json.put(id.toString(), item)
            prefs.edit().putString("items", json.toString()).apply()
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
        val startedAt = System.currentTimeMillis()
        updateHistory(applicationContext, id, repoId, files.firstOrNull().orEmpty(), "running")
        fun report(name: String, done: Long, total: Long) {
            val elapsed = (System.currentTimeMillis() - startedAt).coerceAtLeast(1L)
            val speed = done * 1000L / elapsed
            val eta = if (speed > 0L && total > done) (total - done) / speed else -1L
            setProgressAsync(workDataOf(KEY_FILE to name, KEY_IDX to idx, KEY_COUNT to count, KEY_DONE to done, KEY_TOTAL to total, KEY_SPEED to speed, KEY_ETA to eta))
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
                failed == null -> {
                    updateHistory(applicationContext, id, state = "succeeded")
                    Result.success(workDataOf(
                    KEY_OUT to HfClient.targetDir(base, repoId).absolutePath,
                    KEY_MODEL to File(HfClient.targetDir(base, repoId), files.first()).absolutePath,
                    ))
                }
                runAttemptCount + 1 < MAX_ATTEMPTS -> Result.retry()
                else -> {
                    updateHistory(applicationContext, id, state = "failed", error = "${failed.file}: ${failed.error ?: "gagal"}")
                    Result.failure(workDataOf(KEY_ERROR to "${failed.file}: ${failed.error ?: "gagal"}"))
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (runAttemptCount + 1 < MAX_ATTEMPTS) Result.retry()
            else {
                updateHistory(applicationContext, id, state = "failed", error = e.message ?: "gagal")
                Result.failure(workDataOf(KEY_ERROR to (e.message ?: "gagal")))
            }
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
