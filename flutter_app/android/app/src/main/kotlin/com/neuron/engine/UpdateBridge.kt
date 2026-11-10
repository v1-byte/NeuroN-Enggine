package com.neuron.engine

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
internal object UpdateBridge {
    private const val CHANNEL = "neuron/update"
    private const val RELEASE_API = "https://api.github.com/repos/v1-byte/NeuroN-Enggine/releases/latest"
    private const val APK_MIME = "application/vnd.android.package-archive"

    fun register(messenger: BinaryMessenger, context: Context) {
        val app = context.applicationContext
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkForUpdate" -> scope.launch {
                    runCatching { withContext(Dispatchers.IO) { check(app) } }
                        .onSuccess { result.success(it) }
                        .onFailure { result.error("UPDATE_ERROR", it.message ?: "Gagal mengecek update", null) }
                }
                "downloadAndInstallUpdate" -> {
                    val url = (call.arguments as? Map<*, *>)?.get("url")?.toString().orEmpty()
                    scope.launch {
                        runCatching { withContext(Dispatchers.IO) { downloadAndInstall(app, url) } }
                            .onSuccess { result.success(it) }
                            .onFailure { result.error("UPDATE_ERROR", it.message ?: "Gagal mengunduh update", null) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun connection(url: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 30_000
            requestMethod = "GET"
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "NeuroN-Engine/${BuildConfig.VERSION_NAME}")
        }

    private fun check(ctx: Context): Map<String, Any?> {
        val connection = connection(RELEASE_API)
        val body = connection.inputStream.bufferedReader().use { it.readText() }
        val release = JSONObject(body)
        val assets = release.optJSONArray("assets") ?: return mapOf("available" to false, "reason" to "Release belum memiliki APK")
        var apk: JSONObject? = null
        for (i in 0 until assets.length()) {
            val item = assets.optJSONObject(i) ?: continue
            if (item.optString("name").endsWith(".apk", true)) { apk = item; break }
        }
        val selected = apk ?: return mapOf("available" to false, "reason" to "APK release belum tersedia")
        val tag = release.optString("tag_name")
        if (!isNewer(tag, BuildConfig.VERSION_NAME)) {
            return mapOf("available" to false, "reason" to "APK sudah versi terbaru", "current" to BuildConfig.VERSION_NAME)
        }
        return mapOf(
            "available" to true,
            "tag" to tag,
            "name" to selected.optString("name"),
            "url" to selected.optString("browser_download_url"),
            "size" to selected.optLong("size", 0L),
            "current" to BuildConfig.VERSION_NAME,
            "notes" to release.optString("body"),
        )
    }

    private fun isNewer(rawRemote: String, rawCurrent: String): Boolean {
        fun parts(value: String) = value.removePrefix("v").split(".").map { it.takeWhile { char -> char.isDigit() }.toIntOrNull() ?: 0 }
        val remote = parts(rawRemote)
        val current = parts(rawCurrent)
        for (i in 0 until maxOf(remote.size, current.size)) {
            val a = remote.getOrElse(i) { 0 }
            val b = current.getOrElse(i) { 0 }
            if (a != b) return a > b
        }
        return false
    }

    private fun downloadAndInstall(ctx: Context, rawUrl: String): Map<String, Any> {
        require(rawUrl.startsWith("https://github.com/")) { "Sumber update tidak dipercaya" }
        val target = File(ctx.cacheDir, "updates/neuron-latest.apk").apply { parentFile?.mkdirs(); delete() }
        val connection = connection(rawUrl)
        connection.inputStream.use { input -> target.outputStream().use { output -> input.copyTo(output) } }
        check(target.length() > 0) { "APK hasil unduh kosong" }
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", target)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_MIME)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        ctx.startActivity(intent)
        return mapOf("ok" to true, "path" to target.absolutePath)
    }
}
