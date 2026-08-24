package app.rigel.cast.chrome

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ChromePayloadsTest {
    @Test
    fun buildsControlPayloads() {
        assertEquals("{\"type\":\"CONNECT\"}", ChromePayloads.connect(1))
        assertEquals(
            "{\"type\":\"LAUNCH\",\"appId\":\"CC1AD845\",\"requestId\":2}",
            ChromePayloads.launch("CC1AD845", 2),
        )
        assertEquals("{\"type\":\"GET_STATUS\",\"requestId\":3}", ChromePayloads.getStatus(3))
        assertEquals("{\"type\":\"PING\",\"requestId\":4}", ChromePayloads.ping(4))
        assertEquals("{\"type\":\"PONG\",\"requestId\":5}", ChromePayloads.pong(5))
    }

    @Test
    fun buildsEscapedLoadPayload() {
        val payload = ChromePayloads.load(
            url = "http://host/movie.mp4?x=\"1\"",
            title = "Movie\\Night",
            contentType = "video/mp4",
            requestId = 6,
        )
        assertEquals(
            "{\"type\":\"LOAD\",\"requestId\":6,\"autoplay\":true,\"currentTime\":0," +
                "\"media\":{\"contentId\":\"http://host/movie.mp4?x=\\\"1\\\"\",\"streamType\":\"BUFFERED\"," +
                "\"contentType\":\"video/mp4\",\"metadata\":{\"type\":0,\"title\":\"Movie\\\\Night\"}}}",
            payload,
        )
    }

    @Test
    fun mapsCommonContentTypesAndDefaults() {
        assertEquals("video/mp4", ChromePayloads.contentTypeFor("http://x/a.mp4"))
        assertEquals("application/x-mpegurl", ChromePayloads.contentTypeFor("http://x/a.m3u8?token=1"))
        assertEquals("audio/mpeg", ChromePayloads.contentTypeFor("http://x/a.mp3"))
        assertEquals("video/mp4", ChromePayloads.contentTypeFor("http://x/a.unknown"))
    }

    @Test
    fun extractsReceiverTransportAndMessageFields() {
        val json = """{"requestId":2,"status":{"applications":[{"appId":"CC1AD845","transportId":"transport-1"}]},"type":"RECEIVER_STATUS"}"""
        assertEquals("transport-1", ChromePayloads.extractTransportId(json))
        assertEquals(12, ChromePayloads.requestId("{\"type\":\"MEDIA_STATUS\",\"requestId\":12}"))
        assertNull(ChromePayloads.requestId("{\"type\":\"MEDIA_STATUS\"}"))
        assertEquals("RECEIVER_STATUS", ChromePayloads.messageType(json))
        assertNull(ChromePayloads.errorReason("{\"type\":\"OK\"}"))
        assertEquals("NOT_FOUND", ChromePayloads.errorReason("{\"type\":\"LAUNCH_ERROR\",\"reason\":\"NOT_FOUND\"}"))
    }
}
