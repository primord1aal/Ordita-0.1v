package ru.orbita.taxi.dev

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class DriverPushPayloadTest {
    private val offerId = "0a8ef840-40ee-4f1c-bc41-2e28a87eaff1"
    private val expiration = "2026-11-27T08:15:20.123456+00:00"
    private val timestamp = Instant.parse("2026-11-27T08:15:20.123456Z").toEpochMilli()
    private val offer = mapOf("kind" to "driver_offer", OFFER_ID to offerId, OFFER_EXPIRES_AT to expiration)

    @Test fun offerRequiresTheCompleteBoundedDataOnlyContract() {
        val notice = DriverOfferNotice.parse(offer, timestamp - 25_000)
        assertEquals(offer, notice?.payload())
        assertEquals(timestamp, notice?.expiresAtMillis)
        assertNull(DriverOfferNotice.parse(offer + ("address" to "Учебный адрес"), timestamp - 1))
        assertNull(DriverOfferNotice.parse(offer + (OFFER_ID to "not-an-id"), timestamp - 1))
        assertNull(DriverOfferNotice.parse(offer + (OFFER_EXPIRES_AT to "2026-11-31T08:15:20Z"), timestamp - 1))
        assertNull(DriverOfferNotice.parse(offer + (OFFER_EXPIRES_AT to "2026-11-27T15:15:20+07:00"), timestamp - 1))
    }

    @Test fun offerRejectsExpiredAndOutOfWindowMessages() {
        assertNull(DriverOfferNotice.parse(offer, timestamp))
        assertNull(DriverOfferNotice.parse(offer, timestamp + 1))
        assertNull(DriverOfferNotice.parse(offer, timestamp - 30_001))
        assertNotNull(DriverOfferNotice.parse(offer, timestamp - 1))
    }

    @Test fun backgroundHeartbeatOnlyAcceptsTheFixedTestProjectAndPublicKey() {
        val credentials = mapOf(
            "projectUrl" to DriverHeartbeatCredentials.PROJECT_URL,
            "publishableKey" to "sb_publishable_synthetic_only_0123456789",
            "accessToken" to "synthetic.test.signature",
        )
        assertNotNull(DriverHeartbeatCredentials.parse(credentials))
        assertNull(DriverHeartbeatCredentials.parse(credentials + ("projectUrl" to "https://example.invalid")))
        assertNull(DriverHeartbeatCredentials.parse(credentials + ("publishableKey" to "sb_secret_synthetic_only_123456")))
        assertNull(DriverHeartbeatCredentials.parse(credentials + ("accessToken" to "invalid token\r\n")))
    }
}
