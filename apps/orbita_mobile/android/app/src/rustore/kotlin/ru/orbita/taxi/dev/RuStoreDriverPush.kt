package ru.orbita.taxi.dev

import android.content.Context
import ru.rustore.sdk.core.feature.model.FeatureAvailabilityResult
import ru.rustore.sdk.pushclient.RuStorePushClient
import ru.rustore.sdk.pushclient.common.logger.Logger
import ru.rustore.sdk.pushclient.messaging.model.RemoteMessage
import ru.rustore.sdk.pushclient.messaging.service.RuStoreMessagingService
import ru.rustore.sdk.pushclient.provider.AbstractRuStorePushClientParams

internal object RuStoreDriverPush {
    const val configured = true

    fun getToken(complete: (String?) -> Unit) {
        try {
            RuStorePushClient.checkPushAvailability()
                .addOnSuccessListener { availability ->
                    if (availability == FeatureAvailabilityResult.Available) {
                        readToken(complete)
                    } else {
                        complete(null)
                    }
                }
                .addOnFailureListener { complete(null) }
        } catch (_: RuntimeException) {
            complete(null)
        }
    }

    private fun readToken(complete: (String?) -> Unit) {
        try {
            RuStorePushClient.getToken()
                .addOnSuccessListener { token -> complete(token.takeIf(String::isNotBlank)) }
                .addOnFailureListener { complete(null) }
        } catch (_: RuntimeException) {
            complete(null)
        }
    }
}

class RuStoreOfferMessagingService : RuStoreMessagingService() {
    override fun onNewToken(token: String) {
        DriverPushTokenEvents.changed()
    }

    override fun onMessageReceived(message: RemoteMessage) {
        if (message.notification == null) DriverOfferNotifications.show(applicationContext, message.data)
    }
}

class OrbitaRuStorePushParams(context: Context) : AbstractRuStorePushClientParams(context) {
    override fun getLogger(): Logger = QuietPushLogger
}

private object QuietPushLogger : Logger {
    override fun verbose(message: String, throwable: Throwable?) = Unit
    override fun debug(message: String, throwable: Throwable?) = Unit
    override fun info(message: String, throwable: Throwable?) = Unit
    override fun warn(message: String, throwable: Throwable?) = Unit
    override fun error(message: String, throwable: Throwable?) = Unit
    override fun createLogger(tag: String): Logger = this
}
