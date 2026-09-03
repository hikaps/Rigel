package app.rigel.cast.roku

import app.rigel.cast.RokuDevice
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RokuRendererTest {

    private val deviceInfoXml = """
        <device-info>
          <has-play-on-roku>true</has-play-on-roku>
          <model-name>Roku Ultra</model-name>
        </device-info>
    """.trimIndent()

    private val appsXml = """<apps><app id="15985">Play on Roku</app><app id="2285">Netflix</app></apps>"""

    @Test
    fun fetchDeviceInfoAcceptsPlayOnRokuDevice() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond(deviceInfoXml, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/xml")) }
        val device = RokuRenderer(HttpClient(engine)).fetchDeviceInfo("r1", "http://10.0.0.7:8060")
        assertNotNull(device)
        assertEquals("r1", device.usn)
        assertEquals("http://10.0.0.7:8060/", device.location)
        assertEquals("Roku Ultra", device.modelName)
    }

    @Test
    fun fetchDeviceInfoRejectsWithoutPlayOnRoku() = kotlinx.coroutines.test.runTest {
        val xml = deviceInfoXml.replace("true", "false")
        val engine = MockEngine { respond(xml, HttpStatusCode.OK) }
        assertNull(RokuRenderer(HttpClient(engine)).fetchDeviceInfo("r1", "http://10.0.0.7:8060"))
    }

    @Test
    fun fetchDeviceInfoNullOnNetworkError() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { throw RuntimeException("unreachable") }
        assertNull(RokuRenderer(HttpClient(engine)).fetchDeviceInfo("r1", "http://10.0.0.7:8060"))
    }

    @Test
    fun launchPlayOnRokuResolvesChannelFromApps() = kotlinx.coroutines.test.runTest {
        val posted = mutableListOf<Pair<String, String>>()
        val engine = MockEngine { request ->
            when (request.method) {
                HttpMethod.Get -> respond(appsXml, HttpStatusCode.OK)
                else -> {
                    posted += request.url.toString() to ((request.body as? TextContent)?.text ?: "")
                    respond("", HttpStatusCode.OK)
                }
            }
        }
        val device = RokuDevice("r1", "http://10.0.0.7:8060/", "Roku Ultra")
        val ok = RokuRenderer(HttpClient(engine)).launchPlayOnRoku(device, "http://h/video.mkv")
        assertTrue(ok)
        assertEquals(1, posted.size)
        assertEquals("http://10.0.0.7:8060/input/15985", posted[0].first)
        assertEquals("t=http%3A%2F%2Fh%2Fvideo.mkv", posted[0].second)
    }

    @Test
    fun launchPlayOnRokuFallsBackToConstantChannelId() = kotlinx.coroutines.test.runTest {
        val posted = mutableListOf<String>()
        val engine = MockEngine { request ->
            if (request.method == HttpMethod.Get) {
                respond("""<apps><app id="999">Something Else</app></apps>""", HttpStatusCode.OK)
            } else {
                posted += request.url.toString()
                respond("", HttpStatusCode.OK)
            }
        }
        val device = RokuDevice("r1", "http://10.0.0.7:8060/", "Roku")
        assertTrue(RokuRenderer(HttpClient(engine)).launchPlayOnRoku(device, "http://h/v.mkv"))
        assertEquals("http://10.0.0.7:8060/input/${RokuEcp.PLAY_ON_ROKU_CHANNEL_ID}", posted[0])
    }

    @Test
    fun launchPlayOnRokuFalseOnNon2xx() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { request ->
            if (request.method == HttpMethod.Get) {
                respond(appsXml, HttpStatusCode.OK)
            } else {
                respond("", HttpStatusCode.InternalServerError)
            }
        }
        val device = RokuDevice("r1", "http://10.0.0.7:8060/", "Roku")
        assertFalse(RokuRenderer(HttpClient(engine)).launchPlayOnRoku(device, "http://h/v.mkv"))
    }

    @Test
    fun transportControlsPostKeypress() = kotlinx.coroutines.test.runTest {
        val posted = mutableListOf<String>()
        val engine = MockEngine { request ->
            if (request.method == HttpMethod.Post) posted += request.url.toString()
            respond("", HttpStatusCode.OK)
        }
        val renderer = RokuRenderer(HttpClient(engine))
        val device = RokuDevice("r1", "http://10.0.0.7:8060/", "Roku")
        renderer.play(device)
        renderer.pause(device)
        renderer.stop(device)
        assertEquals(
            listOf(
                "http://10.0.0.7:8060/keypress/Play",
                "http://10.0.0.7:8060/keypress/Pause",
                "http://10.0.0.7:8060/keypress/Home",
            ),
            posted,
        )
    }
}
