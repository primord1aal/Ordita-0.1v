package ru.orbita.taxi.dev

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.NetworkInfo
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetworkInfo
import org.robolectric.shadows.ShadowNetworkCapabilities

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 34])
@Suppress("DEPRECATION")
class NetworkSupportTest {
    private fun caps(vararg transports: Int): NetworkCapabilities = ShadowNetworkCapabilities.newInstance().apply {
        transports.forEach { shadowOf(this).addTransportType(it) }
    }

    @Test fun wifiAndMobileComeFromCapabilities() {
        assertEquals("wifi", NetworkSupport.classify(caps(NetworkCapabilities.TRANSPORT_WIFI)))
        assertEquals("mobile", NetworkSupport.classify(caps(NetworkCapabilities.TRANSPORT_CELLULAR)))
    }

    @Test fun ambiguousNetworkIsNotCalledWifi() {
        assertEquals("unknown", NetworkSupport.classify(null))
        assertEquals("unknown", NetworkSupport.classify(caps(NetworkCapabilities.TRANSPORT_WIFI, NetworkCapabilities.TRANSPORT_CELLULAR)))
        assertEquals("other", NetworkSupport.classify(caps(NetworkCapabilities.TRANSPORT_ETHERNET)))
    }

    @Test fun vpnIsNotPresentedAsUnderlyingWifi() {
        assertEquals("vpn", NetworkSupport.classify(caps(NetworkCapabilities.TRANSPORT_WIFI, NetworkCapabilities.TRANSPORT_VPN)))
    }

    @Test fun snapshotUsesSystemActiveNetwork() {
        val context = RuntimeEnvironment.getApplication()
        val manager = context.getSystemService(ConnectivityManager::class.java)
        val shadow = shadowOf(manager)
        shadow.setActiveNetworkInfo(ShadowNetworkInfo.newInstance(NetworkInfo.DetailedState.CONNECTED, ConnectivityManager.TYPE_WIFI, 0, true, true))
        val active = requireNotNull(manager.activeNetwork)
        shadow.setNetworkCapabilities(active, caps(NetworkCapabilities.TRANSPORT_WIFI))
        val snapshot = NetworkSupport.snapshot(context)
        assertEquals("wifi", snapshot["type"])
        assertEquals(active.networkHandle.toString(), snapshot["networkId"])
    }

    @Test fun noActiveNetworkIsExplicitAndDoesNotNeedLocationPermission() {
        val context = RuntimeEnvironment.getApplication()
        val manager = context.getSystemService(ConnectivityManager::class.java)
        shadowOf(manager).setActiveNetworkInfo(null)
        val declared = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS).requestedPermissions
        assertTrue(declared?.contains(Manifest.permission.ACCESS_NETWORK_STATE) == true)
        // В Robolectric выдаём обычное разрешение явно; реальный Android
        // выдаёт ACCESS_NETWORK_STATE при установке, без runtime-диалога.
        shadowOf(context).grantPermissions(Manifest.permission.ACCESS_NETWORK_STATE)
        shadowOf(context).denyPermissions(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        assertEquals("none", NetworkSupport.snapshot(context)["type"])
    }

    @Test fun processMarkerSurvivesSnapshotsAndOnlyBeginIncrementsAttempt() {
        val context: Context = RuntimeEnvironment.getApplication()
        val first = NetworkSupport.snapshot(context)
        val second = NetworkSupport.snapshot(context, true)
        val third = NetworkSupport.snapshot(context)
        assertEquals(first["processSession"], second["processSession"])
        assertEquals(second["processSession"], third["processSession"])
        assertEquals((first["attempt"] as Int) + 1, second["attempt"])
        assertEquals(second["attempt"], third["attempt"])
        assertEquals(setOf("type", "networkId", "vpn", "proxy", "processSession", "attempt"), third.keys)
    }
}
