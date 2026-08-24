package app.rigel.cast.dlna

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DlnaRendererTest {

    private val deviceXml = """
        <?xml version="1.0"?>
        <root><device>
          <friendlyName>Living Room TV</friendlyName>
          <serviceList><service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <controlURL>/upnp/control/AVTransport1</controlURL>
          </service></serviceList>
        </device></root>
    """.trimIndent()

    private val device = DlnaDevice(
        usn = "u1",
        location = "http://10.0.0.5:1234/desc.xml",
        friendlyName = "Living Room TV",
        controlUrl = "http://10.0.0.5:1234/upnp/control/AVTransport1",
    )

    private val positionXml = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body><u:GetPositionInfoResponse>
            <TrackDuration>01:00:00</TrackDuration><RelTime>00:01:30</RelTime>
          </u:GetPositionInfoResponse></s:Body></s:Envelope>
    """.trimIndent()

    @Test
    fun fetchDeviceDescriptionParsesXml() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond(deviceXml, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/xml")) }
        val renderer = DlnaRenderer(HttpClient(engine))
        val parsed = renderer.fetchDeviceDescription("u1", "http://10.0.0.5:1234/desc.xml")
        assertNotNull(parsed)
        assertEquals("Living Room TV", parsed.friendlyName)
        assertEquals("http://10.0.0.5:1234/upnp/control/AVTransport1", parsed.controlUrl)
    }

    @Test
    fun fetchDeviceDescriptionNullOnHttpError() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("nope", HttpStatusCode.NotFound) }
        assertNull(DlnaRenderer(HttpClient(engine)).fetchDeviceDescription("u1", "http://10.0.0.5:1234/desc.xml"))
    }

    @Test
    fun setAvTransportUriPostsSoapWithEscapedTitle() = kotlinx.coroutines.test.runTest {
        val requests = mutableListOf<Pair<String, String>>()
        val engine = MockEngine { request ->
            val body = (request.body as? TextContent)?.text ?: ""
            requests += request.url.toString() to body
            respond("<ok/>", HttpStatusCode.OK)
        }
        DlnaRenderer(HttpClient(engine)).setAvTransportUri(device, "http://h/movie.mp4", "My & Movie")
        assertEquals(1, requests.size)
        val (url, body) = requests[0]
        assertEquals("http://10.0.0.5:1234/upnp/control/AVTransport1", url)
        assertTrue(body.contains("<u:SetAVTransportURI"))
        assertTrue(body.contains("<CurrentURI>http://h/movie.mp4</CurrentURI>"))
        assertTrue(body.contains("My &amp; Movie"))
    }

    @Test
    fun playPostsPlayAction() = kotlinx.coroutines.test.runTest {
        val requests = mutableListOf<String>()
        val engine = MockEngine { request ->
            requests += (request.body as? TextContent)?.text ?: ""
            respond("<ok/>", HttpStatusCode.OK)
        }
        DlnaRenderer(HttpClient(engine)).play(device)
        assertTrue(requests[0].contains("<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
        assertTrue(requests[0].contains("<Speed>1</Speed>"))
    }

    @Test
    fun seekFormatsTargetTime() = kotlinx.coroutines.test.runTest {
        val requests = mutableListOf<String>()
        val engine = MockEngine { request ->
            requests += (request.body as? TextContent)?.text ?: ""
            respond("<ok/>", HttpStatusCode.OK)
        }
        DlnaRenderer(HttpClient(engine)).seek(device, 90_000)
        assertTrue(requests[0].contains("<Target>00:01:30</Target>"))
    }

    @Test
    fun positionParsesRelAndDuration() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond(positionXml, HttpStatusCode.OK) }
        val pos = DlnaRenderer(HttpClient(engine)).position(device)
        assertNotNull(pos)
        assertEquals(90_000L to 3_600_000L, pos)
    }

    @Test
    fun positionNullWhenResponseMalformed() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("<s:Envelope/>", HttpStatusCode.OK) }
        assertNull(DlnaRenderer(HttpClient(engine)).position(device))
    }

    @Test
    fun transportStateParses() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine {
            respond(
                "<CurrentTransportState>PLAYING</CurrentTransportState>",
                HttpStatusCode.OK,
            )
        }
        assertEquals("PLAYING", DlnaRenderer(HttpClient(engine)).transportState(device))
    }
}
