package app.rigel.cast.dlna

import app.rigel.cast.DlnaDevice

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
        renderingControlUrl = "http://10.0.0.5:1234/upnp/control/RenderingControl1",
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
        assertNull(parsed.renderingControlUrl, "device description without RenderingControl must leave the URL null")
    }

    @Test
    fun fetchDeviceDescriptionParsesRenderingControlUrl() = kotlinx.coroutines.test.runTest {
        val xml = """
            <?xml version="1.0"?>
            <root><device>
              <friendlyName>Living Room TV</friendlyName>
              <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
                <controlURL>/upnp/control/RenderingControl1</controlURL>
              </service>
              <service>
                <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                <controlURL>/upnp/control/AVTransport1</controlURL>
              </service>
              </serviceList>
            </device></root>
        """.trimIndent()
        val engine = MockEngine { respond(xml, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/xml")) }
        val parsed = DlnaRenderer(HttpClient(engine)).fetchDeviceDescription("u1", "http://10.0.0.5:1234/desc.xml")
        assertNotNull(parsed)
        assertEquals("http://10.0.0.5:1234/upnp/control/AVTransport1", parsed.controlUrl)
        assertEquals("http://10.0.0.5:1234/upnp/control/RenderingControl1", parsed.renderingControlUrl)
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

    @Test
    fun resumeReusesPlayAction() = kotlinx.coroutines.test.runTest {
        val requests = mutableListOf<String>()
        val engine = MockEngine { request ->
            requests += (request.body as? TextContent)?.text ?: ""
            respond("<ok/>", HttpStatusCode.OK)
        }
        assertTrue(DlnaRenderer(HttpClient(engine)).resume(device))
        assertTrue(requests[0].contains("<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
    }

    @Test
    fun volumeUpReadsThenStepsVolume() = kotlinx.coroutines.test.runTest {
        val requests = mutableListOf<Pair<String, Pair<String, String>>>() // url to (action header, body)
        val engine = MockEngine { request ->
            val body = (request.body as? TextContent)?.text ?: ""
            requests += request.url.toString() to ((request.headers["SOAPACTION"] ?: "") to body)
            respond("<CurrentVolume>35</CurrentVolume>", HttpStatusCode.OK)
        }
        assertTrue(DlnaRenderer(HttpClient(engine)).volumeUp(device))
        assertEquals(2, requests.size)
        assertEquals("http://10.0.0.5:1234/upnp/control/RenderingControl1", requests[0].first)
        assertEquals("http://10.0.0.5:1234/upnp/control/RenderingControl1", requests[1].first)
        assertTrue(requests[0].second.first.contains("RenderingControl:1#GetVolume"))
        assertTrue(requests[1].second.first.contains("RenderingControl:1#SetVolume"))
        assertTrue(requests[1].second.second.contains("<DesiredVolume>45</DesiredVolume>"))
        assertTrue(requests[1].second.second.contains("xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\""))
    }

    @Test
    fun volumeDownClampsAtZero() = kotlinx.coroutines.test.runTest {
        val requests = mutableListOf<String>()
        val engine = MockEngine { request ->
            requests += (request.body as? TextContent)?.text ?: ""
            respond("<CurrentVolume>3</CurrentVolume>", HttpStatusCode.OK)
        }
        assertTrue(DlnaRenderer(HttpClient(engine)).volumeDown(device))
        assertTrue(requests[1].contains("<DesiredVolume>0</DesiredVolume>"))
    }

    @Test
    fun volumeRequiresRenderingControlUrl() = kotlinx.coroutines.test.runTest {
        val withoutControl = device.copy(renderingControlUrl = null)
        val engine = MockEngine { respond("<unused/>", HttpStatusCode.OK) }
        val renderer = DlnaRenderer(HttpClient(engine))
        assertFalse(renderer.volumeUp(withoutControl))
        assertFalse(renderer.volumeDown(withoutControl))
        assertFalse(renderer.toggleMute(withoutControl))
        assertEquals(0, engine.requestHistory.size)
    }

    @Test
    fun toggleMuteFlipsCurrentMute() = kotlinx.coroutines.test.runTest {
        val requests = mutableListOf<Pair<String, String>>() // action header to body
        val engine = MockEngine { request ->
            requests += (request.headers["SOAPACTION"] ?: "") to ((request.body as? TextContent)?.text ?: "")
            respond("<CurrentMute>0</CurrentMute>", HttpStatusCode.OK)
        }
        assertTrue(DlnaRenderer(HttpClient(engine)).toggleMute(device))
        assertEquals(2, requests.size)
        assertTrue(requests[0].first.contains("RenderingControl:1#GetMute"))
        assertTrue(requests[1].first.contains("RenderingControl:1#SetMute"))
        assertTrue(requests[1].second.contains("<DesiredMute>1</DesiredMute>"))
    }
}
