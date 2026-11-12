package ru.orbita.taxi.dev

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel

/** One foreground fix only; never reads last-known positions or persists coordinates. */
internal class CurrentLocationRequest(
    private val context: Context,
    private val visible: () -> Boolean,
) {
    private val locations = context.getSystemService(LocationManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Pending? = null

    private class Pending(
        val result: MethodChannel.Result,
        val startedAtNanos: Long,
        val listener: LocationListener,
        val timeout: Runnable,
    )

    @SuppressLint("MissingPermission") // Both permission and foreground state checked before registration.
    fun start(result: MethodChannel.Result) {
        if (!visible()) { result.error("not_visible", "Откройте экран карты и повторите попытку", null); return }
        if (pending != null) { result.error("busy", "Дождитесь определения геопозиции", null); return }
        if (!DeviceSupport.hasLocation(context)) { result.error("permission", "Разрешите геопозицию при использовании приложения", null); return }
        if (!DeviceSupport.locationEnabled(context)) { result.error("location_disabled", "Включите геолокацию на телефоне", null); return }

        // GPS and the system network provider work without Google SDK. Coarse-only access
        // uses the network provider, including Android versions requiring fine GPS access.
        val precise = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val providers = locations.getProviders(true).filter {
            it == LocationManager.NETWORK_PROVIDER || (precise && it == LocationManager.GPS_PROVIDER)
        }
        if (providers.isEmpty()) { result.error("unavailable", "Нет доступного источника геопозиции. Проверьте настройки телефона", null); return }

        lateinit var request: Pending
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (pending !== request) return
                if (!visible()) { cancel("not_visible", "Экран карты закрыт"); return }
                if (!DeviceSupport.hasLocation(context)) { cancel("permission", "Доступ к геопозиции отозван"); return }
                if (!DeviceSupport.locationEnabled(context)) { cancel("location_disabled", "Геолокация на телефоне выключена"); return }
                // Some Android providers send a cached first callback. A fresh monotonic
                // timestamp must be at or after this request, independently of wall-clock changes.
                val nowNanos = SystemClock.elapsedRealtimeNanos()
                if (location.elapsedRealtimeNanos <= 0L || location.elapsedRealtimeNanos < request.startedAtNanos ||
                    location.elapsedRealtimeNanos > nowNanos ||
                    !location.latitude.isFinite() || location.latitude !in -90.0..90.0 ||
                    !location.longitude.isFinite() || location.longitude !in -180.0..180.0 ||
                    !location.hasAccuracy() || !location.accuracy.isFinite() || location.accuracy < 0f ||
                    location.time <= 0L) return
                finish(request) {
                    request.result.success(mapOf(
                        "latitude" to location.latitude,
                        "longitude" to location.longitude,
                        "accuracyMeters" to location.accuracy.toDouble(),
                        "capturedAt" to location.time,
                    ))
                }
            }

            override fun onProviderDisabled(provider: String) {
                if (pending === request && providers.none { locations.isProviderEnabled(it) }) {
                    cancel("location_disabled", "Геолокация на телефоне выключена")
                }
            }
            override fun onProviderEnabled(provider: String) = Unit
            @Deprecated("Legacy Android callback")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
        }
        request = Pending(result, SystemClock.elapsedRealtimeNanos(), listener, Runnable {
            if (pending === request) when {
                !visible() -> cancel("not_visible", "Экран карты закрыт")
                !DeviceSupport.hasLocation(context) -> cancel("permission", "Доступ к геопозиции отозван")
                !DeviceSupport.locationEnabled(context) -> cancel("location_disabled", "Геолокация на телефоне выключена")
                else -> cancel("timeout", "Не удалось определить геопозицию за 20 секунд. Попробуйте ещё раз")
            }
        })
        pending = request
        handler.postDelayed(request.timeout, TIMEOUT_MILLIS)
        var registered = false
        for (provider in providers) {
            if (pending !== request) break
            try {
                locations.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
                registered = true
            } catch (_: SecurityException) {
                cancel("permission", "Android не разрешил доступ к геопозиции")
            } catch (_: Exception) {
                // A missing GPS provider must not prevent a network-provider fix.
            }
        }
        if (!registered && pending === request) cancel("unavailable", "Не удалось запустить определение геопозиции. Повторите попытку")
    }

    fun cancel(code: String = "cancelled", message: String = "Определение геопозиции отменено") {
        val request = pending ?: return
        finish(request) { request.result.error(code, message, null) }
    }

    private fun finish(request: Pending, reply: () -> Unit) {
        if (pending !== request) return
        pending = null
        handler.removeCallbacks(request.timeout)
        try { locations.removeUpdates(request.listener) } catch (_: Exception) { /* Permission may have been revoked. */ }
        reply()
    }

    companion object { const val TIMEOUT_MILLIS = 20_000L }
}
