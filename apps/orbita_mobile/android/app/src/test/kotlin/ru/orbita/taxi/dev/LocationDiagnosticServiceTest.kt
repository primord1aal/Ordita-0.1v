package ru.orbita.taxi.dev

import android.Manifest
import android.app.Application
import android.app.NotificationManager
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationManager
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ServiceController
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class LocationDiagnosticServiceTest {
    private lateinit var app: Application
    private var controller: ServiceController<LocationDiagnosticService>? = null

    @Before fun prepare() {
        app = RuntimeEnvironment.getApplication()
        app.getSharedPreferences(LocationDiagnosticService.PREFS, Context.MODE_PRIVATE).edit().clear().commit()
        shadowOf(app).denyPermissions(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_BACKGROUND_LOCATION, Manifest.permission.POST_NOTIFICATIONS)
        shadowOf(app.getSystemService(LocationManager::class.java)).setLocationEnabled(true)
        shadowOf(app.getSystemService(NotificationManager::class.java)).setNotificationsEnabled(true)
    }

    @After fun cleanup() { controller?.destroy() }

    private fun service(): LocationDiagnosticService {
        controller = Robolectric.buildService(LocationDiagnosticService::class.java).create()
        return controller!!.get()
    }

    @Test fun missingPermissionDoesNotStartTracking() {
        val service = service()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(Intent(), 0, 1))
        assertFalse(LocationDiagnosticService.running)
        assertTrue(shadowOf(service).isStoppedBySelf)
    }

    @Test fun foregroundOnlyPermissionStartsWithoutAlwaysAccess() {
        shadowOf(app).grantPermissions(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.POST_NOTIFICATIONS)
        val service = service()
        service.onStartCommand(Intent(), 0, 1)
        assertTrue(LocationDiagnosticService.running)
        assertEquals(PackageManager.PERMISSION_DENIED, app.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION))
        assertNotNull(shadowOf(service).lastForegroundNotification)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION, service.foregroundServiceType)
    }

    @Test fun notificationDenialDoesNotStartDiagnostic() {
        shadowOf(app).grantPermissions(Manifest.permission.ACCESS_FINE_LOCATION)
        service().onStartCommand(Intent(), 0, 1)
        assertFalse(LocationDiagnosticService.running)
    }

    @Test fun disabledLocationDoesNotStartDiagnostic() {
        shadowOf(app).grantPermissions(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.POST_NOTIFICATIONS)
        shadowOf(app.getSystemService(LocationManager::class.java)).setLocationEnabled(false)
        service().onStartCommand(Intent(), 0, 1)
        assertFalse(LocationDiagnosticService.running)
    }

    @Test fun serviceIsPrivateAndDeclaresLocationType() {
        val info = app.packageManager.getServiceInfo(ComponentName(app, LocationDiagnosticService::class.java), 0)
        assertFalse(info.exported)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION, info.foregroundServiceType)
    }

    @Test fun positionCallbackStoresFreshnessButNoCoordinates() {
        shadowOf(app).grantPermissions(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.POST_NOTIFICATIONS)
        val service = service()
        assertEquals(Service.START_NOT_STICKY, service.onStartCommand(Intent(), 0, 1))
        service.onLocationChanged(Location("test").apply { latitude = 0.0; longitude = 0.0; time = System.currentTimeMillis() - 60_000 })
        val saved = app.getSharedPreferences(LocationDiagnosticService.PREFS, Context.MODE_PRIVATE).all
        assertEquals(setOf("startedAt", "lastHeartbeat", "lastFix", "fixCount"), saved.keys)
        assertEquals(1, saved["fixCount"])
        assertTrue((saved["lastFix"] as Long) <= System.currentTimeMillis() - 59_000)
    }

    @Test fun notificationStopActionStopsTheService() {
        shadowOf(app).grantPermissions(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.POST_NOTIFICATIONS)
        val service = service()
        service.onStartCommand(Intent(), 0, 1)
        service.onStartCommand(Intent().setAction(LocationDiagnosticService.STOP), 0, 2)
        assertTrue(shadowOf(service).isStoppedBySelf)
        controller!!.destroy(); controller = null
        assertFalse(LocationDiagnosticService.running)
    }
}
