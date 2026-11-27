package ru.orbita.taxi.dev

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection

internal class DriverHeartbeatCredentials private constructor(
    val publishableKey: String,
    val accessToken: String,
) {
    companion object {
        const val PROJECT_URL = "https://fjqghohhohgvwlmefdmo.supabase.co"
        private val publicKey = Regex("sb_publishable_[A-Za-z0-9_-]{16,250}")
        private val jwt = Regex("[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+")

        fun parse(values: Map<*, *>): DriverHeartbeatCredentials? {
            if (values["projectUrl"] != PROJECT_URL) return null
            val key = (values["publishableKey"] as? String)?.takeIf(publicKey::matches) ?: return null
            val token = (values["accessToken"] as? String)
                ?.takeIf { it.length <= 8_192 && jwt.matches(it) } ?: return null
            return DriverHeartbeatCredentials(key, token)
        }
    }
}

class DriverShiftHeartbeatService : Service() {
    companion object {
        private const val CHANNEL = "orbita_driver_shift"
        private const val NOTIFICATION_ID = 28404
        private const val INTERVAL_MS = 4_000L
        private const val RECEIPT_LIMIT_MS = 12_000L

        @Volatile private var credentials: DriverHeartbeatCredentials? = null
        @Volatile internal var activityVisible: Boolean = false

        internal fun start(context: Context, values: Map<*, *>): Boolean {
            if (!activityVisible || !RuStoreDriverPush.configured || !DriverOfferNotifications.isEnabled(context) ||
                !DriverOfferNotifications.notificationsAllowed(context)
            ) return false
            val next = DriverHeartbeatCredentials.parse(values) ?: return false
            credentials = next
            val intent = Intent(context, DriverShiftHeartbeatService::class.java)
            return try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
                true
            } catch (_: RuntimeException) {
                stop(context)
                false
            }
        }

        internal fun stop(context: Context) {
            credentials = null
            context.stopService(Intent(context, DriverShiftHeartbeatService::class.java))
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val network = Executors.newSingleThreadScheduledExecutor()
    private var scheduled = false
    private var lastReceipt = SystemClock.elapsedRealtime()
    private var installedCredentials: DriverHeartbeatCredentials? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val session = credentials
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && manager?.getNotificationChannel(CHANNEL) == null) {
            manager?.createNotificationChannel(NotificationChannel(CHANNEL, "Рабочая смена", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(
            this, NOTIFICATION_ID, Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = DeviceSupport.basicNotification(this, CHANNEL, "Орбита · рабочая смена", "Поддерживаем связь с сервером в фоне.")
            .setOngoing(true)
            .setContentIntent(open)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            else startForeground(NOTIFICATION_ID, notification)
        } catch (_: RuntimeException) {
            if (credentials === session) credentials = null
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (session == null || !DriverOfferNotifications.notificationsAllowed(this)) {
            if (credentials === session) credentials = null
            stopSelf(startId)
            return START_NOT_STICKY
        }
        installedCredentials = session
        if (!scheduled) {
            scheduled = true
            network.scheduleWithFixedDelay(::refresh, 0L, INTERVAL_MS, TimeUnit.MILLISECONDS)
        }
        return START_NOT_STICKY
    }

    private fun refresh() {
        val session = credentials ?: return
        if (activityVisible) {
            // The ordinary Flutter poll renews the line while the activity is visible.
            lastReceipt = SystemClock.elapsedRealtime()
            return
        }
        val receipt = if (DriverOfferNotifications.notificationsAllowed(this)) heartbeat(session) else Receipt.STOP
        if (credentials !== session) return
        when (receipt) {
            Receipt.LIVE -> lastReceipt = SystemClock.elapsedRealtime()
            Receipt.RETRY -> if (SystemClock.elapsedRealtime() - lastReceipt >= RECEIPT_LIMIT_MS) stopIfCurrent(session)
            Receipt.STOP -> stopIfCurrent(session)
        }
    }

    private fun stopIfCurrent(session: DriverHeartbeatCredentials) {
        main.post {
            if (credentials === session) {
                credentials = null
                stopSelf()
            }
        }
    }

    private enum class Receipt { LIVE, RETRY, STOP }

    private fun heartbeat(session: DriverHeartbeatCredentials): Receipt {
        val endpoint = DriverHeartbeatCredentials.PROJECT_URL + "/rest/v1/rpc/orbita_driver_heartbeat"
        val connection = try {
            URL(endpoint).openConnection() as HttpsURLConnection
        } catch (_: java.io.IOException) {
            return Receipt.RETRY
        }
        try {
            val deadline = SystemClock.elapsedRealtime() + 4_500L
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 1_800
            connection.readTimeout = 1_800
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("apikey", session.publishableKey)
            connection.setRequestProperty("Authorization", "Bearer ${session.accessToken}")
            val body = "{}".toByteArray(Charsets.UTF_8)
            connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream.use { it.write(body) }
            return when (connection.responseCode) {
                200 -> connection.inputStream.use { stream ->
                    val response = StringBuilder()
                    while (response.length < 16) {
                        val remaining = deadline - SystemClock.elapsedRealtime()
                        if (remaining <= 0L) return Receipt.RETRY
                        connection.readTimeout = minOf(remaining.toInt(), 1_800)
                        val next = stream.read()
                        if (next == -1) {
                            return if (response.toString().trim() == "true") Receipt.LIVE else Receipt.STOP
                        }
                        response.append(next.toChar())
                    }
                    Receipt.STOP
                }
                429, in 500..599 -> Receipt.RETRY
                else -> Receipt.STOP
            }
        } catch (_: java.io.IOException) {
            return Receipt.RETRY
        } finally {
            connection.disconnect()
        }
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        if (credentials === installedCredentials) credentials = null
        stopSelf(startId)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (credentials === installedCredentials) credentials = null
        stopSelf()
    }

    override fun onDestroy() {
        if (credentials === installedCredentials) credentials = null
        network.shutdownNow()
        main.removeCallbacksAndMessages(null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
