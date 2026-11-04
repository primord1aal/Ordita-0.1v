package ru.orbita.taxi.dev

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build

internal object DeviceSupport {
    const val TEST_CHANNEL = "orbita_local_test_v1"
    const val LOCATION_CHANNEL = "orbita_location_check_v1"
    const val OPEN_CHECKS = "orbita_open_checks"
    const val TEST_ID = 2101
    const val LOCATION_ID = 2102

    fun hasLocation(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(TEST_CHANNEL, "Тестовые уведомления", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Локальная проверка, без заказов и серверного Push"
            })
            manager.createNotificationChannel(NotificationChannel(LOCATION_CHANNEL, "Проверка геолокации", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Состояние вручную запущенной проверки геопозиции"
            })
        }
    }

    fun notificationsAllowed(context: Context): Boolean {
        ensureChannels(context)
        val manager = context.getSystemService(NotificationManager::class.java)
        val permission = Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        val channels = Build.VERSION.SDK_INT < 26 || listOf(TEST_CHANNEL, LOCATION_CHANNEL).all { manager.getNotificationChannel(it)?.importance != NotificationManager.IMPORTANCE_NONE }
        return permission && manager.areNotificationsEnabled() && channels
    }

    fun locationEnabled(context: Context): Boolean {
        val manager = context.getSystemService(LocationManager::class.java)
        return if (Build.VERSION.SDK_INT >= 28) manager.isLocationEnabled else
            manager.isProviderEnabled(LocationManager.GPS_PROVIDER) || manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }

    fun notification(context: Context, channel: String, title: String, body: String): Notification.Builder {
        ensureChannels(context)
        val intent = Intent(context, MainActivity::class.java).putExtra(OPEN_CHECKS, true).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(context, 41, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel) else Notification.Builder(context)
        return builder.setSmallIcon(R.drawable.ic_stat_orbita).setContentTitle(title).setContentText(body)
            .setContentIntent(pending).setVisibility(Notification.VISIBILITY_PRIVATE)
    }

    fun snapshot(context: Context): Map<String, Any> {
        val prefs = context.getSharedPreferences(LocationDiagnosticService.PREFS, Context.MODE_PRIVATE)
        val precise = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val background = Build.VERSION.SDK_INT < 29 || context.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "notifications" to notificationsAllowed(context),
            "location" to if (precise) "precise" else if (hasLocation(context)) "approximate" else "denied",
            "backgroundLocation" to background,
            "locationEnabled" to locationEnabled(context),
            "serviceRunning" to LocationDiagnosticService.running,
            "startedAt" to prefs.getLong("startedAt", 0),
            "lastHeartbeat" to prefs.getLong("lastHeartbeat", 0),
            "lastFix" to prefs.getLong("lastFix", 0),
            "fixCount" to prefs.getInt("fixCount", 0),
        )
    }
}
