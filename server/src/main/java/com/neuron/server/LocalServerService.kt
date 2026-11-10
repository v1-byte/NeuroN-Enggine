package com.neuron.server

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.neuron.project.ProjectRepository
import com.neuron.model.SecretStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File

data class ServerState(val running: Boolean = false, val address: String? = null, val error: String? = null)

/**
 * Server lokal sebagai foreground service (tipe specialUse, tidak kena batas 6 jam dataSync di Android 15).
 * Menahan wake lock & Wi-Fi lock agar tetap hidup saat layar mati. Notifikasi menampilkan IP:port dan tombol Stop.
 */
class LocalServerService : Service() {

    companion object {
        const val ACTION_START = "com.neuron.server.START"
        const val ACTION_STOP = "com.neuron.server.STOP"
        private const val CHANNEL = "local_server"
        private const val NOTIF_ID = 4201

        private val _state = MutableStateFlow(ServerState())
        val state: StateFlow<ServerState> = _state.asStateFlow()

        fun start(ctx: Context) {
            ContextCompat.startForegroundService(ctx, Intent(ctx, LocalServerService::class.java).setAction(ACTION_START))
        }

        fun stop(ctx: Context) {
            ctx.startService(Intent(ctx, LocalServerService::class.java).setAction(ACTION_STOP))
        }
    }

    private var server: LocalServer? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopServer()
            stopSelf()
            return START_NOT_STICKY
        }
        // Dimulai ulang oleh sistem (intent null): hanya lanjut bila server terakhir memang diaktifkan.
        if (intent == null && !ServerPrefs(this).enabled) {
            stopSelf()
            return START_NOT_STICKY
        }
        // startForeground harus dipanggil di setiap start, termasuk bila server sudah berjalan (cegah ANR/crash 5 detik).
        startFg("Menyiapkan server…", null)
        if (server == null) launchServer()
        return START_STICKY
    }

    private fun launchServer() {
        val prefs = ServerPrefs(this)
        try {
            check(prefs.apiKey.length >= ServerPrefs.MIN_KEY_LENGTH) { "API key wajib diisi (minimal ${ServerPrefs.MIN_KEY_LENGTH} karakter)" }
            val repo = ProjectRepository(File(filesDir, "projects"))
            val bindHost = NetInfo.localIpv4() ?: "127.0.0.1"
            val srv = LocalServer(
                projectProvider = {
                    val project = repo.loadOrCreate("default")
                    val providerKey = SecretStore(applicationContext, "neuron_secrets").get("apiKey") ?: ""
                    project.copy(engine = project.engine.copy(apiKey = providerKey))
                },   // config dan secret API dibaca ulang tiap permintaan
                apiKey = prefs.apiKey,
                port = prefs.port,
                host = bindHost,
            )
            srv.start()
            server = srv
            acquireLocks()
            prefs.enabled = true
            val addr = "http://$bindHost:${prefs.port}"
            _state.value = ServerState(running = true, address = addr)
            startFg("Aktif di $addr", addr)
        } catch (e: Exception) {
            val msg = e.message ?: "gagal menjalankan server"
            stopServer()
            _state.value = ServerState(running = false, error = msg)
            stopSelf()
        }
    }

    private fun stopServer() {
        runCatching { server?.stop() }
        server = null
        releaseLocks()
        ServerPrefs(this).enabled = false
        _state.value = ServerState()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    override fun onDestroy() {
        stopServer()
        super.onDestroy()
    }

    private fun startFg(title: String, text: String?) {
        createChannel()
        val type = if (Build.VERSION.SDK_INT >= 34) android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, NOTIF_ID, notification(title, text), type)
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel(CHANNEL, "Server lokal", NotificationManager.IMPORTANCE_LOW))
    }

    private fun notification(title: String, text: String?): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, LocalServerService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("NeuroN Server")
            .setContentText(text ?: title)
            .setSubText(title)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopIntent)
            .build()
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        val pm = getSystemService(PowerManager::class.java)
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "NeuroN:server").apply {
            setReferenceCounted(false)
            acquire()
        }
        val wm = applicationContext.getSystemService(WifiManager::class.java)
        wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "NeuroN:server").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }
}
