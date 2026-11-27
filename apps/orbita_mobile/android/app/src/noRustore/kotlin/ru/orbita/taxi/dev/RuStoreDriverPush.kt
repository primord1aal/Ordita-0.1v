package ru.orbita.taxi.dev

import android.app.Service
import android.content.Intent
import android.os.IBinder

internal object RuStoreDriverPush {
    const val configured = false

    fun getToken(complete: (String?) -> Unit) = complete(null)
}

// Declared disabled and non-exported when this source set is selected.
class RuStoreOfferMessagingService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
}
