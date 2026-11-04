package ru.orbita.taxi.dev

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

/** Только снимок активной сети. Нет HTTP, номеров SIM, SSID, DNS-имён и записи на диск. */
object NetworkSupport {
    private val processSession = UUID.randomUUID().toString()
    private val attempts = AtomicInteger(0)

    fun classify(capabilities: NetworkCapabilities?): String {
        if (capabilities == null) return "unknown"
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return "vpn"
        val wifi = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        val mobile = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
        return when {
            wifi && !mobile -> "wifi"
            mobile && !wifi -> "mobile"
            wifi && mobile -> "unknown"
            else -> "other"
        }
    }

    fun snapshot(context: Context, beginProbe: Boolean = false): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>(
            "type" to "unknown", "networkId" to null,
            "vpn" to null, "proxy" to null,
            "processSession" to processSession,
            "attempt" to if (beginProbe) attempts.incrementAndGet() else attempts.get()
        )
        try {
            val manager = context.getSystemService(ConnectivityManager::class.java) ?: return result
            val network = manager.activeNetwork
            result["proxy"] = manager.defaultProxy != null
            if (network == null) {
                result["type"] = "none"
                result["vpn"] = false
                return result
            }
            val caps = manager.getNetworkCapabilities(network)
            result["networkId"] = network.networkHandle.toString()
            result["type"] = classify(caps)
            result["vpn"] = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        } catch (_: Exception) {
            // Недоступный Android-снимок не выдаётся за Wi-Fi или мобильную сеть.
        }
        return result
    }
}
