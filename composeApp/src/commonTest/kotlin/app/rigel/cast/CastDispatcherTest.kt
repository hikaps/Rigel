package app.rigel.cast

import app.rigel.bridge.DiscoveryBridge
import app.rigel.bridge.HttpServerBridge
import app.rigel.bridge.ProbeBridge
import app.rigel.bridge.ProbeResult
import app.rigel.bridge.RigelBridgeFactory
import app.rigel.bridge.SsdpDevice
import app.rigel.bridge.TranscodeBridge
import app.rigel.cast.dlna.DlnaDevice
import app.rigel.cast.kodi.KodiDevice
import app.rigel.cast.roku.RokuDevice
import app.rigel.player.PlayerPhase
import app.rigel.player.PlayerUiState
import app.rigel.source.jellyfin.JellyfinSession
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.runBlocking
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Fake bridge layer so the LAN URL resolution path is deterministic. */
private class FakeBridges(private val lan: String?) :
    DiscoveryBridge, ProbeBridge, TranscodeBridge, HttpServerBridge {
    override fun ssdpSearch(searchTargets: List<String>, timeoutMs: Int, onResult: (List<SsdpDevice>) -> Unit) = Unit
    override fun probe(url: String, headers: Map<String, String>, onResult: (ProbeResult?, String?) -> Unit) = Unit
    override fun startHlsSession(
        sessionId: String,
        sourceUrl: String,
        headers: Map<String, String>,
        mode: String,
        onReady: (String?, String?) -> Unit,
    ) = Unit

    override fun stopHlsSession(sessionId: String) = Unit
    override fun start(onStarted: (port: Long, errorMsg: String?) -> Unit) = Unit
    override fun stop() = Unit
    override fun lanBaseUrl(): String? = lan
}

class CastDispatcherTest {
    private val withLan = FakeBridges(lan = "http://192.168.1.5:8080")

    @BeforeTest
    fun registerBridges() {
        RigelBridgeFactory.register(withLan, withLan, withLan, withLan)
    }

    @AfterTest
    fun resetBridges() {
        RigelBridgeFactory.register(null, null, null, null)
    }

    private fun playing(
        sourceUrl: String? = "http://origin/v.mkv",
        proxyUrl: String? = null,
        filename: String? = null,
    ) = PlayerUiState(
        phase = PlayerPhase.PLAYING,
        sourceUrl = sourceUrl,
        filename = filename,
        proxyUrl = proxyUrl,
    )

    @Test
    fun remoteUrlIsLanProxyWhenProxySessionActive() {
        val state = playing(proxyUrl = "http://127.0.0.1:12345/session-abc/index.m3u8")
        assertEquals(
            "http://192.168.1.5:8080/session-abc/index.m3u8",
            CastDispatcher.remoteCastUrl(state),
        )
    }

    @Test
    fun remoteUrlIsSourceWhenPlayingDirect() {
        assertEquals("http://origin/v.mkv", CastDispatcher.remoteCastUrl(playing()))
    }

    @Test
    fun remoteUrlNullWhenNotPlaying() {
        assertNull(CastDispatcher.remoteCastUrl(PlayerUiState(phase = PlayerPhase.IDLE)))
    }

    @Test
    fun remoteUrlNullWhenProxyWithoutLanUrl() {
        RigelBridgeFactory.register(null, null, null, FakeBridges(lan = null))
        val state = playing(proxyUrl = "http://127.0.0.1:12345/session-x/index.m3u8")
        assertNull(CastDispatcher.remoteCastUrl(state))
    }

    @Test
    fun titlePrefersFilenameThenUrlBasenameThenFallback() {
        assertEquals("Movie", CastDispatcher.remoteCastTitle(playing(filename = "Movie")))
        assertEquals("v.mkv", CastDispatcher.remoteCastTitle(playing(filename = null)))
        assertEquals("Stream", CastDispatcher.remoteCastTitle(playing(sourceUrl = null, filename = null)))
    }

    @Test
    fun rokuCapabilitiesNoteDocumented() {
        val caps = CastDispatcher.capabilities(CastTarget.Roku(RokuDevice("u", "http://10.0.0.9:8060/", "Roku")))
        assertTrue(!caps.supportsSeek)
        assertTrue(caps.note!!.contains("no seek"))
    }

    @Test
    fun dlnaAndKodiCapabilitiesFullControl() {
        val dlna = CastTarget.Dlna(DlnaDevice("u", "http://10.0.0.9/rootDesc.xml", "TV", "http://10.0.0.9/ctl"))
        assertTrue(dlna.let { CastDispatcher.capabilities(it) }.supportsSeek)
        assertTrue(dlna.let { CastDispatcher.capabilities(it) }.supportsPosition)
        val kodi = CastTarget.Kodi(KodiDevice("u", "http://10.0.0.9:8080", "Kodi"))
        assertTrue(CastDispatcher.capabilities(kodi).supportsSeek)
        assertTrue(CastDispatcher.capabilities(kodi).supportsPosition)
    }

    @Test
    fun jellyfinSessionCastNotAvailableFromDeviceSheet() {
        val session = CastTarget.JellyfinSessionTarget(JellyfinSession("s1", "Living Room", "Jellyfin Web"))
        val result = runBlocking { CastDispatcher.cast(session, "http://x/v.mkv", "Movie") }
        assertTrue(result.contains("library items"))
    }

    // --- Adapter dispatch (mock HTTP engine) ---

    @Test
    fun dlnaCastFiresSetAvTransportUriThenPlayWithLanUrl() {
        val lanUrl = "http://192.168.1.5:8080/session-abc/index.m3u8"
        val engine = MockEngine { request ->
            respond(
                content = """<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:SetAVTransportURIResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/></s:Body></s:Envelope>""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/xml"),
            )
        }
        val client = HttpClient(engine)
        val target = CastTarget.Dlna(DlnaDevice("u1", "http://10.0.0.9/rootDesc.xml", "TV", "http://10.0.0.9/ctl"))

        val result = runBlocking { CastDispatcher.cast(target, lanUrl, "Movie", client) }

        assertEquals("Sent to TV", result)
        assertEquals(2, engine.requestHistory.size)
        val setUri = engine.requestHistory[0]
        val play = engine.requestHistory[1]
        assertEquals(HttpMethod.Post, setUri.method)
        assertEquals("http://10.0.0.9/ctl", setUri.url.toString())
        assertTrue(setUri.headers["SOAPACTION"]!!.contains("SetAVTransportURI"))
        val setUriBody = (setUri.body as? TextContent)?.text ?: ""
        assertTrue(setUriBody.contains(lanUrl))
        assertTrue(play.headers["SOAPACTION"]!!.contains("#Play"))
    }

    @Test
    fun kodiCastPostsPlayerOpenAndReportsSuccess() {
        val engine = MockEngine { request ->
            respond(
                content = """{"jsonrpc":"2.0","id":1,"result":["OK"]}""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "application/json"),
            )
        }
        val client = HttpClient(engine)
        val target = CastTarget.Kodi(KodiDevice("k1", "http://10.0.0.7:8080", "Kodi"))

        val result = runBlocking { CastDispatcher.cast(target, "http://192.168.1.5:8080/session-x/index.m3u8", "Movie", client) }

        assertEquals("Sent to Kodi", result)
        val req = engine.requestHistory.single()
        assertEquals("http://10.0.0.7:8080/jsonrpc", req.url.toString())
        val body = (req.body as? TextContent)?.text ?: ""
        assertTrue(body.contains("\"Player.Open\""))
    }

    @Test
    fun kodiCastReportsRejectionWhenResponseContainsError() {
        val engine = MockEngine { request ->
            respond(
                content = """{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params"}}""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "application/json"),
            )
        }
        val client = HttpClient(engine)
        val target = CastTarget.Kodi(KodiDevice("k1", "http://10.0.0.7:8080", "Kodi"))

        val result = runBlocking { CastDispatcher.cast(target, "http://x/v.mkv", "Movie", client) }

        assertEquals("Kodi rejected the URL", result)
    }
}
