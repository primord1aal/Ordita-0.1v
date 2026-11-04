package ru.orbita.taxi.dev

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private var pendingPermission: MethodChannel.Result? = null
    private var activityVisible = false

    @SuppressLint("MissingPermission") // Показ уведомления защищён notificationsAllowed.
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "ru.orbita.taxi.foundation/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "snapshot" -> result.success(NetworkSupport.snapshot(applicationContext))
                    "beginProbe" -> result.success(NetworkSupport.snapshot(applicationContext, true))
                    else -> result.notImplemented()
                }
            }
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "ru.orbita.taxi.foundation/device")
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "capabilities" -> result.success(DeviceSupport.snapshot(this))
                    "consumeLaunchRequest" -> {
                        val requested = intent?.getBooleanExtra(DeviceSupport.OPEN_CHECKS, false) == true
                        intent?.removeExtra(DeviceSupport.OPEN_CHECKS)
                        result.success(requested)
                    }
                    "requestNotifications" -> if (Build.VERSION.SDK_INT >= 33) request(arrayOf(Manifest.permission.POST_NOTIFICATIONS), result) else result.success(null)
                    "requestForegroundLocation" -> request(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION), result)
                    "requestBackgroundLocation" -> {
                        if (!DeviceSupport.hasLocation(this)) result.error("permission", "Сначала разрешите геопозицию при использовании", null)
                        else if (Build.VERSION.SDK_INT >= 30) { openSettings(); result.success(null) }
                        else if (Build.VERSION.SDK_INT == 29) request(arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION), result)
                        else result.success(null)
                    }
                    "openSettings" -> { openSettings(); result.success(null) }
                    "showLocalNotification" -> {
                        if (!DeviceSupport.notificationsAllowed(this)) result.error("permission", "Уведомления не разрешены", null)
                        else {
                            val builder = DeviceSupport.notification(this, DeviceSupport.TEST_CHANNEL, "Орбита: проверка", "Локальное уведомление. Заказ не создан.").setAutoCancel(true)
                            if (Build.VERSION.SDK_INT < 26) builder.setPriority(android.app.Notification.PRIORITY_HIGH).setDefaults(android.app.Notification.DEFAULT_ALL)
                            getSystemService(NotificationManager::class.java).notify(DeviceSupport.TEST_ID, builder.build())
                            result.success(null)
                        }
                    }
                    "startLocationDiagnostic" -> {
                        if (!activityVisible || !DeviceSupport.hasLocation(this) || !DeviceSupport.notificationsAllowed(this) || !DeviceSupport.locationEnabled(this)) {
                            result.error("not_ready", "Запустите проверку с открытого экрана после выдачи разрешений", null)
                        } else {
                            val service = Intent(this, LocationDiagnosticService::class.java)
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
                            result.success(null)
                        }
                    }
                    "stopLocationDiagnostic" -> { stopService(Intent(this, LocationDiagnosticService::class.java)); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("android_action", "Android не разрешил действие. Проверьте настройки приложения", null)
            }
        }
    }

    private fun request(permissions: Array<String>, result: MethodChannel.Result) {
        if (!activityVisible || pendingPermission != null) { result.error("busy", "Дождитесь завершения предыдущего действия", null); return }
        pendingPermission = result
        requestPermissions(permissions, 612)
    }

    private fun openSettings() {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(code, permissions, grants)
        if (code == 612) { val result = pendingPermission; pendingPermission = null; result?.success(null) }
    }

    override fun onResume() { super.onResume(); activityVisible = true }
    override fun onPause() { activityVisible = false; super.onPause() }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra(DeviceSupport.OPEN_CHECKS, false) && ::channel.isInitialized) {
            intent.removeExtra(DeviceSupport.OPEN_CHECKS)
            channel.invokeMethod("openChecks", null)
        }
    }

    override fun onDestroy() {
        pendingPermission?.error("closed", "Экран закрыт", null)
        pendingPermission = null
        super.onDestroy()
    }
}
