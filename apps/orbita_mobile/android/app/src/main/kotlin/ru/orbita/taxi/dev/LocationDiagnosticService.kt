package ru.orbita.taxi.dev

import android.app.PendingIntent
import android.app.Service
import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/** Только диагностика: нет хранения координат, сети, заказов или скрытого старта. */
class LocationDiagnosticService : Service(), LocationListener {
    companion object {
        const val PREFS = "orbita_location_diagnostic"
        const val STOP = "ru.orbita.taxi.dev.STOP_DIAGNOSTIC"
        @Volatile var running = false
            private set
    }

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var locations: LocationManager
    private val heartbeat = object : Runnable {
        override fun run() {
            if (!running) return
            if (!DeviceSupport.hasLocation(this@LocationDiagnosticService)) { stopSelf(); return }
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putLong("lastHeartbeat", System.currentTimeMillis()).apply()
            handler.postDelayed(this, 15_000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        locations = getSystemService(LocationManager::class.java)
    }

    @SuppressLint("MissingPermission") // Перед запросом проверено фактическое разрешение.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) { stopSelf(); return START_NOT_STICKY }
        if (!DeviceSupport.hasLocation(this) || !DeviceSupport.notificationsAllowed(this) || !DeviceSupport.locationEnabled(this)) {
            stopSelf(); return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        try {
            val stop = PendingIntent.getService(this, 42, Intent(this, LocationDiagnosticService::class.java).setAction(STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val notification = DeviceSupport.notification(this, DeviceSupport.LOCATION_CHANNEL, "Орбита: проверка геолокации", "Служба работает. Координаты не передаются.")
                .setOngoing(true).setOnlyAlertOnce(true)
                .addAction(android.R.drawable.ic_media_pause, "Остановить", stop).build()
            if (Build.VERSION.SDK_INT >= 29) startForeground(DeviceSupport.LOCATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            else startForeground(DeviceSupport.LOCATION_ID, notification)
            val now = System.currentTimeMillis()
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().clear().putLong("startedAt", now).putLong("lastHeartbeat", now).apply()
            running = true
            val precise = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
            val providers = if (precise) listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER) else listOf(LocationManager.NETWORK_PROVIDER)
            for (provider in providers) {
                if (locations.isProviderEnabled(provider)) locations.requestLocationUpdates(provider, 15_000L, 0f, this, Looper.getMainLooper())
            }
            handler.post(heartbeat)
        } catch (_: Exception) {
            running = false
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onLocationChanged(location: Location) {
        // Намеренно не читаем latitude/longitude и не сохраняем Location.
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        prefs.edit().putLong("lastFix", location.time.coerceAtMost(System.currentTimeMillis())).putInt("fixCount", prefs.getInt("fixCount", 0) + 1).apply()
    }
    override fun onProviderEnabled(provider: String) {}
    override fun onProviderDisabled(provider: String) {}
    @Deprecated("Совместимость Android 7–10")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        running = false
        handler.removeCallbacksAndMessages(null)
        try { locations.removeUpdates(this) } catch (_: Exception) { }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
