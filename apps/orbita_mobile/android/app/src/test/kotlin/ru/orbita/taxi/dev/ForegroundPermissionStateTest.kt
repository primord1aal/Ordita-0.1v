package ru.orbita.taxi.dev

import android.Manifest
import android.app.Application
import android.content.Context
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
class ForegroundPermissionStateTest {
    private lateinit var app: Application

    @Before fun prepare() {
        app = RuntimeEnvironment.getApplication()
        app.getSharedPreferences(DeviceSupport.FOREGROUND_PERMISSION_PREFS, Context.MODE_PRIVATE)
            .edit().clear().commit()
        shadowOf(app).denyPermissions(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
    }

    @Test fun firstInstallDoesNotClaimPermanentDenial() {
        val state = DeviceSupport.snapshot(app)
        assertEquals(false, state["foregroundLocationRequested"])
        assertEquals(false, state["locationPermanentlyDenied"])
    }

    @Test fun grantedApproximateLocationOverridesPreviousDenialFlag() {
        app.getSharedPreferences(DeviceSupport.FOREGROUND_PERMISSION_PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(DeviceSupport.FOREGROUND_PERMISSION_REQUESTED, true).commit()
        shadowOf(app).grantPermissions(Manifest.permission.ACCESS_COARSE_LOCATION)
        val state = DeviceSupport.snapshot(app)
        assertEquals("approximate", state["location"])
        assertEquals(true, state["foregroundLocationRequested"])
        assertEquals(false, state["locationPermanentlyDenied"])
    }
}
