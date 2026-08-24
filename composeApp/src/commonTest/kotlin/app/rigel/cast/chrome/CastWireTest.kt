package app.rigel.cast.chrome

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CastWireTest {
    @Test
    fun encodeAndDecodeRoundTrip() {
        val frame = CastFrame(
            sourceId = "sender-0",
            destinationId = "receiver-0",
            namespace = ChromePayloads.NS_CONNECTION,
            payloadUtf8 = "{\"type\":\"CONNECT\"}",
        )
        assertEquals(frame, CastWire.decode(CastWire.encode(frame)))
    }

    @Test
    fun encodedFrameHasExpectedCastMessageFields() {
        val encoded = CastWire.encode(
            CastFrame("sender-0", "receiver-0", ChromePayloads.NS_CONNECTION, "{\"type\":\"CONNECT\"}"),
        )
        val prefix = byteArrayOf(0x08, 0x00, 0x12, 0x08) + "sender-0".encodeToByteArray() +
            byteArrayOf(0x1a, 0x0a) + "receiver-0".encodeToByteArray() +
            byteArrayOf(0x22, 0x28)
        assertTrue(encoded.copyOf(prefix.size).contentEquals(prefix))
    }

    @Test
    fun malformedFramesReturnNull() {
        assertNull(CastWire.decode(byteArrayOf(0x08)))
        assertNull(CastWire.decode(byteArrayOf(0x12, 0x05, 0x01)))
        assertNull(CastWire.decode("garbage".encodeToByteArray()))
    }
}
