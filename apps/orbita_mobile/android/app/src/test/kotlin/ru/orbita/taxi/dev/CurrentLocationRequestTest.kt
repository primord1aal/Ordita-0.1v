package ru.orbita.taxi.dev

import android.Manifest
import android.app.Application
import android.content.Context
import android.location.Location
import android.location.LocationManager
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import java.time.Duration
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CurrentLocationRequestTest {
    private lateinit var app: Application
    private lateinit var locations: LocationManager
    private lateinit var request: CurrentLocationRequest
    private var visible = true

    private class Reply : MethodChannel.Result {
        var value: Any? = null
        var code: String? = null
        var completions = 0
        override fun success(result: Any?) { value = result; completions++ }
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) { code = errorCode; completions++ }
        override fun notImplemented() { fail("Method must be implemented") }
    }

    @Before fun prepare() {
        app = RuntimeEnvironment.getApplication()
        shadowOf(app).denyPermissions(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        locations = app.getSystemService(LocationManager::class.java)
        shadowOf(locations).setLocationEnabled(true)
        shadowOf(locations).setProviderEnabled(LocationManager.GPS_PROVIDER, true)
        shadowOf(locations).setProviderEnabled(LocationManager.NETWORK_PROVIDER, true)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(1))
        visible = true
        request = CurrentLocationRequest(app) { visible }
    }

    @After fun cleanup() { request.cancel() }

    private fun permitPrecise() {
        shadowOf(app).grantPermissions(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
    }

    private fun fresh(provider: String = LocationManager.GPS_PROVIDER) = Location(provider).apply {
        latitude = 55.012
        longitude = 82.432
        accuracy = 12.5f
        time = System.currentTimeMillis()
        elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
    }

    private fun deliver(location: Location) {
        shadowOf(locations).simulateLocation(location)
        shadowOf(Looper.getMainLooper()).idle()
    }

    @Test fun deniedPermissionDoesNotReturnCoordinates() {
        val reply = Reply()
        request.start(reply)
        assertEquals("permission", reply.code)
        assertNull(reply.value)
    }

    @Test fun hiddenActivityDoesNotStartRequest() {
        permitPrecise()
        visible = false
        val reply = Reply()
        request.start(reply)
        assertEquals("not_visible", reply.code)
    }

    @Test fun disabledLocationHasExplicitFailure() {
        permitPrecise()
        shadowOf(locations).setLocationEnabled(false)
        val reply = Reply()
        request.start(reply)
        assertEquals("location_disabled", reply.code)
    }

    @Test fun freshFixCompletesOnceAndDoesNotPersistCoordinatesOrStartService() {
        permitPrecise()
        val before = app.getSharedPreferences(LocationDiagnosticService.PREFS, Context.MODE_PRIVATE).all
        val reply = Reply()
        request.start(reply)
        deliver(fresh())
        deliver(fresh(LocationManager.NETWORK_PROVIDER))
        assertNull(reply.code)
        assertEquals(1, reply.completions)
        val fix = reply.value as Map<*, *>
        assertEquals(55.012, fix["latitude"])
        assertEquals(82.432, fix["longitude"])
        assertEquals(12.5, fix["accuracyMeters"])
        assertEquals(setOf("latitude", "longitude", "accuracyMeters", "capturedAt"), fix.keys)
        assertEquals(before, app.getSharedPreferences(LocationDiagnosticService.PREFS, Context.MODE_PRIVATE).all)
        assertNull(shadowOf(app).nextStartedService)
    }

    @Test fun networkProviderWorksWhenGpsDisabled() {
        permitPrecise()
        shadowOf(locations).setProviderEnabled(LocationManager.GPS_PROVIDER, false)
        val reply = Reply()
        request.start(reply)
        deliver(fresh(LocationManager.NETWORK_PROVIDER))
        assertNull(reply.code)
        assertEquals(1, reply.completions)
        assertNotNull(reply.value)
    }

    @Test fun approximateForegroundAccessDoesNotRequireBackgroundPermission() {
        shadowOf(app).grantPermissions(Manifest.permission.ACCESS_COARSE_LOCATION)
        val reply = Reply()
        request.start(reply)
        deliver(fresh(LocationManager.NETWORK_PROVIDER).apply { accuracy = 1200f })
        assertNull(reply.code)
        assertEquals(1200.0, (reply.value as Map<*, *>)["accuracyMeters"])
    }

    @Test fun staleOrInvalidCallbacksWaitForFreshAccurateFix() {
        permitPrecise()
        val reply = Reply()
        request.start(reply)
        deliver(fresh().apply { elapsedRealtimeNanos = 1L })
        deliver(fresh().apply { removeAccuracy() })
        deliver(fresh().apply { longitude = Double.NaN })
        assertEquals(0, reply.completions)
        deliver(fresh())
        assertEquals(1, reply.completions)
        assertNotNull(reply.value)
    }

    @Test fun missingFixTimesOutAndAllowsAnotherRequest() {
        permitPrecise()
        val reply = Reply()
        request.start(reply)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(CurrentLocationRequest.TIMEOUT_MILLIS + 1))
        assertEquals("timeout", reply.code)
        assertNull(reply.value)
        val next = Reply()
        request.start(next)
        deliver(fresh())
        assertNotNull(next.value)
    }

    @Test fun concurrentRequestIsRejectedWithoutOverwritingFirst() {
        permitPrecise()
        val first = Reply()
        val second = Reply()
        request.start(first)
        request.start(second)
        assertEquals("busy", second.code)
        deliver(fresh())
        assertNotNull(first.value)
        assertEquals(1, second.completions)
    }

    @Test fun pauseCancellationDropsLateFixAndTimeout() {
        permitPrecise()
        val reply = Reply()
        request.start(reply)
        visible = false
        request.cancel("not_visible", "Экран карты закрыт")
        deliver(fresh())
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(CurrentLocationRequest.TIMEOUT_MILLIS + 1))
        assertEquals("not_visible", reply.code)
        assertNull(reply.value)
        assertEquals(1, reply.completions)
    }

    @Test fun revokedPermissionDuringRequestDoesNotReturnLatePosition() {
        permitPrecise()
        val reply = Reply()
        request.start(reply)
        shadowOf(app).denyPermissions(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        deliver(fresh())
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(CurrentLocationRequest.TIMEOUT_MILLIS + 1))
        assertEquals("permission", reply.code)
        assertNull(reply.value)
    }

    @Test fun switchingLocationOffDuringRequestDoesNotReturnPosition() {
        permitPrecise()
        val reply = Reply()
        request.start(reply)
        shadowOf(locations).setLocationEnabled(false)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(CurrentLocationRequest.TIMEOUT_MILLIS + 1))
        assertEquals("location_disabled", reply.code)
        assertNull(reply.value)
    }
}
