package ru.orbita.taxi.dev

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

internal const val OPEN_DRIVER_OFFER = "ru.orbita.taxi.dev.OPEN_DRIVER_OFFER"
internal const val OFFER_ID = "offer_id"
internal const val OFFER_EXPIRES_AT = "expires_at"

internal data class DriverOfferNotice(val offerId: String, val expiresAt: String, val expiresAtMillis: Long) {
    fun payload(): Map<String, String> = mapOf("kind" to "driver_offer", OFFER_ID to offerId, OFFER_EXPIRES_AT to expiresAt)

    companion object {
        private val id = Regex("[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}")
        private val utcTime = Regex("""(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,6}))?(?:Z|\+00:00)""")

        fun parse(data: Map<String, String>, now: Long): DriverOfferNotice? {
            if (data.size != 3 || data["kind"] != "driver_offer") return null
            val offerId = data[OFFER_ID]?.takeIf(id::matches) ?: return null
            val expiresAt = data[OFFER_EXPIRES_AT] ?: return null
            val time = utcTime.matchEntire(expiresAt) ?: return null
            val fraction = time.groupValues[2].padEnd(3, '0').take(3)
            val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT).apply {
                isLenient = false
                timeZone = TimeZone.getTimeZone("UTC")
            }
            val expiry = try {
                formatter.parse("${time.groupValues[1]}.${fraction}Z")?.time ?: return null
            } catch (_: java.text.ParseException) {
                return null
            }
            // 25 секунд на предложение и небольшой запас на расхождение часов.
            if (expiry - now !in 1L..30_000L) return null
            return DriverOfferNotice(offerId, expiresAt, expiry)
        }
    }
}

internal object DriverOfferNotifications {
    const val CHANNEL = "orbita_driver_offers"
    private const val NOTIFICATION_ID = 28403
    private const val PREFS = "driver_offer_notifications"
    private const val ENABLED = "enabled"
    private const val SEEN = "seen_offers"
    private const val MAX_SEEN = 64
    private var displayedOffer: String? = null

    @Synchronized
    fun setEnabled(context: Context, enabled: Boolean): Boolean {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        if (enabled) {
            ensureChannel(manager)
        } else {
            displayedOffer = null
            manager.cancel(NOTIFICATION_ID)
        }
        return preferences.getBoolean(ENABLED, false) == enabled ||
            preferences.edit().putBoolean(ENABLED, enabled).commit()
    }

    @Synchronized
    @SuppressLint("MissingPermission") // Android permission and notification status are checked before posting.
    fun show(context: Context, message: Map<String, String>) {
        val now = System.currentTimeMillis()
        val offer = DriverOfferNotice.parse(message, now) ?: return
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!preferences.getBoolean(ENABLED, false)) return
        if (!notificationsAllowed(context)) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        ensureChannel(manager)
        if (Build.VERSION.SDK_INT >= 26 &&
            manager.getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE
        ) return

        val seen = seenOffers(preferences.getStringSet(SEEN, emptySet()).orEmpty(), now)
        if (seen.any { it.substringBefore(':') == offer.offerId }) return
        val remember = setOf("${offer.offerId}:${offer.expiresAtMillis}") + seen.take(MAX_SEEN - 1)
        if (!preferences.edit().putStringSet(SEEN, remember).commit()) return

        val remaining = offer.expiresAtMillis - System.currentTimeMillis()
        if (remaining <= 0L) return
        val intent = Intent(context, MainActivity::class.java)
            .setAction(OPEN_DRIVER_OFFER)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(OFFER_ID, offer.offerId)
            .putExtra(OFFER_EXPIRES_AT, offer.expiresAt)
        val open = PendingIntent.getActivity(
            context, NOTIFICATION_ID, intent, PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = DeviceSupport.basicNotification(context, CHANNEL, "Новый заказ", "Откройте Орбиту, чтобы проверить предложение.")
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
        if (Build.VERSION.SDK_INT >= 26) {
            notification.setTimeoutAfter(remaining)
        } else {
            @Suppress("DEPRECATION")
            notification.setPriority(Notification.PRIORITY_HIGH)
                .setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
        }
        try {
            manager.notify(NOTIFICATION_ID, notification.build())
        } catch (_: SecurityException) {
            // Permission may change after the check above.
            return
        }
        displayedOffer = offer.offerId
        if (Build.VERSION.SDK_INT < 26) {
            Handler(Looper.getMainLooper()).postDelayed({ expire(manager, offer.offerId) }, remaining)
        }
    }

    fun notificationsAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return false
        return context.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() == true
    }

    fun isEnabled(context: Context): Boolean = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .getBoolean(ENABLED, false)

    @Synchronized
    fun wasDisplayed(context: Context, offer: DriverOfferNotice): Boolean {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return preferences.getStringSet(SEEN, emptySet()).orEmpty().contains("${offer.offerId}:${offer.expiresAtMillis}")
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(CHANNEL) != null) return
        val sound = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build()
        val channel = NotificationChannel(CHANNEL, "Предложения водителю", NotificationManager.IMPORTANCE_HIGH)
        channel.setSound(sound, attributes)
        manager.createNotificationChannel(channel)
    }

    private fun seenOffers(saved: Set<String>, now: Long): List<String> = saved
        .mapNotNull { key -> key.substringAfter(':').toLongOrNull()?.let { key to it } }
        .filter { (_, expiry) -> expiry > now }
        .sortedByDescending { (_, expiry) -> expiry }
        .map { (key, _) -> key }

    @Synchronized
    private fun expire(manager: NotificationManager, offerId: String) {
        if (displayedOffer != offerId) return
        manager.cancel(NOTIFICATION_ID)
        displayedOffer = null
    }
}

internal object DriverPushTokenEvents {
    // Flutter binds and unbinds this listener on the main thread.
    var onChanged: (() -> Unit)? = null

    fun changed() = Handler(Looper.getMainLooper()).post { onChanged?.invoke() }
}
