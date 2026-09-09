package app.rigel.cast.kodi

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

class KodiRendererTest {

    private val positionJson = """
        {"id":1,"jsonrpc":"2.0","result":{"percentage":25.0,
         "time":{"hours":0,"minutes":1,"seconds":2,"milliseconds":500},
         "totaltime":{"hours":0,"minutes":4,"seconds":10,"milliseconds":0}}}
    """.trimIndent()

    @Test
    fun isKodiTrueOn2xx() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("", HttpStatusCode.OK) }
        assertTrue(KodiRenderer(HttpClient(engine)).isKodi("http://10.0.0.5:8080"))
    }

    @Test
    fun isKodiFalseOn4xx() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("", HttpStatusCode.NotFound) }
        assertFalse(KodiRenderer(HttpClient(engine)).isKodi("http://10.0.0.5:8080"))
    }

    @Test
    fun isKodiFalseOnNetworkError() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { throw RuntimeException("unreachable") }
        assertFalse(KodiRenderer(HttpClient(engine)).isKodi("http://10.0.0.5:8080"))
    }

    @Test
    fun launchPostsPlayerOpenAndSucceeds() = kotlinx.coroutines.test.runTest {
        val posted = mutableListOf<Pair<String, String>>()
        val engine = MockEngine { request ->
            posted += request.url.toString() to ((request.body as? TextContent)?.text ?: "")
            respond("""{"id":1,"jsonrpc":"2.0","result":"OK"}""", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
        }
        val renderer = KodiRenderer(HttpClient(engine))
        assertTrue(renderer.launch("http://10.0.0.5:8080", "http://h/v.mkv"))
        assertEquals("http://10.0.0.5:8080/jsonrpc", posted[0].first)
        assertTrue(posted[0].second.contains("\"method\":\"Player.Open\""))
        assertTrue(posted[0].second.contains("\"file\":\"http://h/v.mkv\""))
    }

    @Test
    fun launchFalseWhenRpcReturnsError() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("""{"error":{"code":-32601}}""", HttpStatusCode.OK) }
        assertFalse(KodiRenderer(HttpClient(engine)).launch("http://10.0.0.5:8080", "http://h/v.mkv"))
    }

    @Test
    fun transportRpcBodies() = kotlinx.coroutines.test.runTest {
        val posted = mutableListOf<String>()
        val engine = MockEngine { request ->
            posted += (request.body as? TextContent)?.text ?: ""
            respond("""{"id":1,"jsonrpc":"2.0","result":"OK"}""", HttpStatusCode.OK)
        }
        val renderer = KodiRenderer(HttpClient(engine))
        renderer.playPause("http://10.0.0.5:8080")
        renderer.stop("http://10.0.0.5:8080")
        renderer.seek("http://10.0.0.5:8080", 42.5)
        assertEquals(3, posted.size)
        assertTrue(posted[0].contains("\"method\":\"Player.PlayPause\""))
        assertTrue(posted[1].contains("\"method\":\"Player.Stop\""))
        assertTrue(posted[2].contains("\"method\":\"Player.Seek\""))
        assertTrue(posted[2].contains("\"percentage\":42.5"))
    }

    @Test
    fun positionParsesTimeObjects() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond(positionJson, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json")) }
        val pos = KodiRenderer(HttpClient(engine)).position("http://10.0.0.5:8080")
        assertNotNull(pos)
        assertEquals(62_500L to 250_000L, pos)
    }

    @Test
    fun positionNullWhenPlayerGone() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("""{"result":{}}""", HttpStatusCode.OK) }
        assertNull(KodiRenderer(HttpClient(engine)).position("http://10.0.0.5:8080"))
    }

    @Test
    fun positionNullOnRpcFailure() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { throw RuntimeException("unreachable") }
        assertNull(KodiRenderer(HttpClient(engine)).position("http://10.0.0.5:8080"))
    }

    @Test
    fun pauseTogglesOnlyWhenPlaying() = kotlinx.coroutines.test.runTest {
        val posted = mutableListOf<String>()
        val engine = MockEngine { request ->
            posted += (request.body as? TextContent)?.text ?: ""
            respond("""{"id":1,"jsonrpc":"2.0","result":{"percentage":50.0,"speed":1}}""", HttpStatusCode.OK)
        }
        assertTrue(KodiRenderer(HttpClient(engine)).pause("http://10.0.0.5:8080"))
        assertEquals(2, posted.size)
        assertTrue(posted[0].contains("\"method\":\"Player.GetProperties\""))
        assertTrue(posted[0].contains("\"speed\""))
        assertTrue(posted[1].contains("\"method\":\"Player.PlayPause\""))
    }

    @Test
    fun pauseWhenAlreadyPausedIsSuccessWithoutToggle() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine {
            respond("""{"id":1,"jsonrpc":"2.0","result":{"speed":0}}""", HttpStatusCode.OK)
        }
        assertTrue(KodiRenderer(HttpClient(engine)).pause("http://10.0.0.5:8080"))
        assertEquals(1, engine.requestHistory.size, "already-paused must not send the toggle")
    }

    @Test
    fun resumeTogglesOnlyWhenPaused() = kotlinx.coroutines.test.runTest {
        val posted = mutableListOf<String>()
        val engine = MockEngine { request ->
            posted += (request.body as? TextContent)?.text ?: ""
            respond("""{"id":1,"jsonrpc":"2.0","result":{"speed":0}}""", HttpStatusCode.OK)
        }
        assertTrue(KodiRenderer(HttpClient(engine)).resume("http://10.0.0.5:8080"))
        assertEquals(2, posted.size)
        assertTrue(posted[1].contains("\"method\":\"Player.PlayPause\""))
    }

    @Test
    fun pauseFalseWhenPlayerGone() = kotlinx.coroutines.test.runTest {
        val engine = MockEngine { respond("""{"error":{"code":-32100,"message":"Invalid player id"}}""", HttpStatusCode.OK) }
        assertFalse(KodiRenderer(HttpClient(engine)).pause("http://10.0.0.5:8080"))
    }

    @Test
    fun volumeAndMuteUseApplicationNamespace() = kotlinx.coroutines.test.runTest {
        val posted = mutableListOf<String>()
        val engine = MockEngine { request ->
            posted += (request.body as? TextContent)?.text ?: ""
            respond("""{"id":1,"jsonrpc":"2.0","result":"OK"}""", HttpStatusCode.OK)
        }
        val renderer = KodiRenderer(HttpClient(engine))
        assertTrue(renderer.volumeUp("http://10.0.0.5:8080"))
        assertTrue(renderer.volumeDown("http://10.0.0.5:8080"))
        assertTrue(renderer.toggleMute("http://10.0.0.5:8080"))
        assertEquals(3, posted.size)
        assertTrue(posted[0].contains("\"method\":\"Application.SetVolume\""))
        assertTrue(posted[0].contains("\"volume\":\"increment\""))
        assertTrue(posted[1].contains("\"volume\":\"decrement\""))
        assertTrue(posted[2].contains("\"method\":\"Application.SetMute\""))
        assertTrue(posted[2].contains("\"mute\":\"toggle\""))
    }
}
