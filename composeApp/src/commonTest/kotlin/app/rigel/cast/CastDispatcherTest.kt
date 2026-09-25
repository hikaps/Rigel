package app.rigel.cast

import app.rigel.bridge.DiscoveryBridge
import app.rigel.bridge.HttpServerBridge
import app.rigel.bridge.ProbeBridge
import app.rigel.bridge.ProbeOperation
import app.rigel.bridge.ProbeResult
import app.rigel.bridge.RigelBridgeFactory
import app.rigel.bridge.SsdpDevice
import app.rigel.bridge.TranscodeBridge
import app.rigel.cast.chrome.ChromeAdapter
import app.rigel.cast.dlna.DlnaRenderer
import app.rigel.cast.ChromeDevice
import app.rigel.cast.DlnaDevice
import app.rigel.cast.KodiDevice
import app.rigel.cast.RokuDevice
import app.rigel.source.jellyfin.JellyfinSession
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue


/** Fake bridge layer so the LAN URL resolution path is deterministic. */
private class FakeBridges(private val lan: String?) :
    DiscoveryBridge, ProbeBridge, TranscodeBridge, HttpServerBridge {
    override fun ssdpSearch(searchTargets: List<String>, timeoutMs: Int, onResult: (List<SsdpDevice>) -> Unit) = Unit
    override fun probe(url: String, headers: Map<String, String>, onResult: (ProbeResult?, String?) -> Unit): ProbeOperation =
        object : ProbeOperation {
            override fun cancel() = Unit
        }
    override fun startHlsSession(
        sessionId: String,
        sourceUrl: String,
        headers: Map<String, String>,
        mode: String,
        passthroughAudioCodecs: List<String>,
        startOffsetMs: Long,
        subtitleTracks: List<app.rigel.bridge.SubtitleTrack>,
        waitForCompletion: Boolean,
        onReady: (String?, String?) -> Unit,
        onError: (String) -> Unit,
    ) = Unit

    override fun stopHlsSession(sessionId: String) = Unit
    override fun start(onStarted: (port: Long, errorMsg: String?) -> Unit) = Unit
    override fun stop() = Unit
    override fun lanBaseUrl(): String? = lan
}

/** Records cast-active mirroring without a PlayerController. */
private class RecordingPort : CastPlaybackPort {
    var active = false
    var stopRequested = false
    override fun setCastActive(active: Boolean) {
        this.active = active
    }

    override fun remoteCastUrl(): String? = null
    override fun remoteCastTitle(): String = "Stream"
    override fun stopPlayback() {
        stopRequested = true
        active = false
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class CastDispatcherTest {
    private val withLan = FakeBridges(lan = "http://192.168.1.5:8080")
    private val port = RecordingPort()
    private val defaultClient = HttpClient(MockEngine { respond("") })

    @BeforeTest
    fun registerBridges() {
        CastDispatcher.install(port, defaultClient)
        CastDispatcher.clearActive()
        RigelBridgeFactory.register(withLan, withLan, withLan, withLan)
    }

    @AfterTest
    fun resetBridges() {
        CastDispatcher.clearActive()
        CastDispatcher.install(null, null)
        RigelBridgeFactory.register(null, null, null, null)
    }

    @Test
    fun remoteUrlIsLanProxyWhenProxySessionActive() {
        assertEquals(
            "http://192.168.1.5:8080/session-abc/index.m3u8",
            CastDispatcher.remoteCastUrl(
                isPlaying = true,
                proxyUrl = "http://127.0.0.1:12345/session-abc/index.m3u8",
                sourceUrl = "http://origin/v.mkv",
            ),
        )
    }

    @Test
    fun remoteUrlRehostsLanFormattedProxyPathAtLanBase() {
        // Regression: since the AirPlay fix the proxy URL is LAN-formatted;
        // the path must be re-hosted at the current LAN base without the old
        // 127.0.0.1 delimiter (which would mangle it into //host:port/…).
        RigelBridgeFactory.register(null, null, null, FakeBridges(lan = "http://10.0.0.5:8090"))
        assertEquals(
            "http://10.0.0.5:8090/session-abc/index.m3u8",
            CastDispatcher.remoteCastUrl(
                isPlaying = true,
                proxyUrl = "http://192.168.1.5:8080/session-abc/index.m3u8",
                sourceUrl = "http://origin/v.mkv",
            ),
        )
    }

    @Test
    fun remoteUrlIsSourceWhenPlayingDirect() {
        assertEquals(
            "http://origin/v.mkv",
            CastDispatcher.remoteCastUrl(isPlaying = true, proxyUrl = null, sourceUrl = "http://origin/v.mkv"),
        )
    }

    @Test
    fun remoteUrlNullWhenNotPlaying() {
        assertNull(CastDispatcher.remoteCastUrl(isPlaying = false, proxyUrl = null, sourceUrl = "http://origin/v.mkv"))
    }

    @Test
    fun remoteUrlNullWhenProxyWithoutLanUrl() {
        RigelBridgeFactory.register(null, null, null, FakeBridges(lan = null))
        assertNull(
            CastDispatcher.remoteCastUrl(
                isPlaying = true,
                proxyUrl = "http://127.0.0.1:12345/session-x/index.m3u8",
                sourceUrl = "http://origin/v.mkv",
            ),
        )
    }

    @Test
    fun titlePrefersFilenameThenUrlBasenameThenFallback() {
        assertEquals("Movie", CastDispatcher.remoteCastTitle("Movie", "http://origin/v.mkv"))
        assertEquals("v.mkv", CastDispatcher.remoteCastTitle(null, "http://origin/v.mkv"))
        assertEquals("Stream", CastDispatcher.remoteCastTitle(null, null))
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
        val dlnaCaps = CastDispatcher.capabilities(dlna)
        assertTrue(dlnaCaps.supportsSeek)
        assertTrue(dlnaCaps.supportsPosition)
        assertTrue(dlnaCaps.supportsPauseResume)
        assertTrue(dlnaCaps.supportsStop)
        assertTrue(dlnaCaps.supportsVolume)
        val kodi = CastTarget.Kodi(KodiDevice("u", "http://10.0.0.9:8080", "Kodi"))
        val kodiCaps = CastDispatcher.capabilities(kodi)
        assertTrue(kodiCaps.supportsSeek)
        assertTrue(kodiCaps.supportsPosition)
        assertTrue(kodiCaps.supportsPauseResume)
        assertTrue(kodiCaps.supportsStop)
        assertTrue(kodiCaps.supportsVolume)
    }

    @Test
    fun jellyfinSessionCastNotAvailableFromDeviceSheet() {
        val session = CastTarget.JellyfinSessionTarget(JellyfinSession("s1", "Living Room", "Jellyfin Web"))
        val result = runBlocking { CastDispatcher.cast(session, "http://x/v.mkv", "Movie") }
        assertTrue(result.message.contains("library items"))
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

        assertEquals("Sent to TV", result.message)
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

        assertEquals("Sent to Kodi", result.message)
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

        assertEquals("Kodi rejected the URL", result.message)
    }
    @Test
    fun successfulCastTracksActiveTargetAndDlnaSeekUsesRelativeTime() {
        val engine = MockEngine {
            respond(
                content = """<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/></s:Body></s:Envelope>""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/xml"),
            )
        }
        val client = HttpClient(engine)
        val target = CastTarget.Dlna(DlnaDevice("u2", "http://10.0.0.9/rootDesc.xml", "TV", "http://10.0.0.9/ctl"))

        runBlocking { CastDispatcher.cast(target, "http://origin/v.mp4", "Movie", client) }
        assertEquals(target, CastDispatcher.activeTarget())
        assertTrue(port.active, "successful cast must mirror castActive through the port")
        assertTrue(runBlocking { CastDispatcher.seekActive(30_000, 60_000, client) })

        val seekBody = (engine.requestHistory[2].body as? TextContent)?.text ?: ""
        assertTrue(engine.requestHistory[2].headers["SOAPACTION"]!!.contains("#Seek"))
        assertTrue(seekBody.contains("<Unit>REL_TIME</Unit>"))
        assertTrue(seekBody.contains("<Target>00:00:30</Target>"))
    }

    @Test
    fun activeKodiSeekUsesPercentage() {
        val engine = MockEngine {
            respond(
                content = """{"jsonrpc":"2.0","id":1,"result":"OK"}""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "application/json"),
            )
        }
        val client = HttpClient(engine)
        val target = CastTarget.Kodi(KodiDevice("k2", "http://10.0.0.7:8080", "Kodi"))

        runBlocking { CastDispatcher.cast(target, "http://origin/v.mp4", "Movie", client) }
        assertTrue(runBlocking { CastDispatcher.seekActive(30_000, 60_000, client) })

        val body = (engine.requestHistory[1].body as? TextContent)?.text ?: ""
        assertTrue(body.contains("\"Player.Seek\""))
        assertTrue(body.contains("\"percentage\":50.0"))
    }

    // --- Remote-control dispatch (pause/resume/stop/volume) ---

    @Test
    fun remoteControlOpsWithoutActiveSessionReturnFalse() {
        val engine = MockEngine { respond("", HttpStatusCode.OK) }
        val client = HttpClient(engine)
        runBlocking {
            assertFalse(CastDispatcher.pauseActive(client))
            assertFalse(CastDispatcher.resumeActive(client))
            assertFalse(CastDispatcher.stopActive(client))
            assertFalse(CastDispatcher.volumeUpActive(client))
            assertFalse(CastDispatcher.volumeDownActive(client))
            assertFalse(CastDispatcher.toggleMuteActive(client))
        }
        assertEquals(0, engine.requestHistory.size)
    }

    @Test
    fun activeDlnaPauseAndVolumeDispatchSoap() {
        val engine = MockEngine {
            respond(
                content = "<CurrentVolume>20</CurrentVolume>",
                status = HttpStatusCode.OK,
            )
        }
        val client = HttpClient(engine)
        val target = CastTarget.Dlna(
            DlnaDevice(
                "rc1",
                "http://10.0.0.9/rootDesc.xml",
                "TV",
                "http://10.0.0.9/ctl",
                renderingControlUrl = "http://10.0.0.9/rc",
            ),
        )

        runBlocking { CastDispatcher.cast(target, "http://origin/v.mp4", "Movie", client) }
        assertTrue(runBlocking { CastDispatcher.pauseActive(client) })
        assertTrue(runBlocking { CastDispatcher.volumeUpActive(client) })

        // cast = SetURI + Play; pause = AVTransport Pause; volume = GetVolume + SetVolume on RenderingControl.
        assertEquals(5, engine.requestHistory.size)
        val pause = engine.requestHistory[2]
        assertEquals("http://10.0.0.9/ctl", pause.url.toString())
        assertTrue(pause.headers["SOAPACTION"]!!.contains("AVTransport:1#Pause"))
        assertEquals("http://10.0.0.9/rc", engine.requestHistory[3].url.toString())
        assertTrue(engine.requestHistory[3].headers["SOAPACTION"]!!.contains("RenderingControl:1#GetVolume"))
        assertEquals("http://10.0.0.9/rc", engine.requestHistory[4].url.toString())
        val setVolumeBody = (engine.requestHistory[4].body as? TextContent)?.text ?: ""
        assertTrue(setVolumeBody.contains("<DesiredVolume>30</DesiredVolume>"))
        assertEquals(target, CastDispatcher.activeTarget(), "pause/volume must not end the session")
        assertTrue(port.active)
    }

    @Test
    fun activeRokuPausePostsEcpKeypress() {
        val engine = MockEngine { request ->
            if (request.method == HttpMethod.Get) {
                respond("""<apps><app id="15985">Play on Roku</app></apps>""", HttpStatusCode.OK)
            } else {
                respond("", HttpStatusCode.OK)
            }
        }
        val client = HttpClient(engine)
        val target = CastTarget.Roku(RokuDevice("r9", "http://10.0.0.9:8060/", "Roku Ultra"))

        val result = runBlocking { CastDispatcher.cast(target, "http://origin/v.mp4", "Movie", client) }
        assertTrue(result.message.contains("Sent"))
        assertTrue(runBlocking { CastDispatcher.pauseActive(client) })
        assertTrue(runBlocking { CastDispatcher.stopActive(client) })

        // cast = GET query/apps + POST input/15985; pause/stop = keypress posts.
        val urls = engine.requestHistory.map { it.url.toString() }
        assertEquals(
            listOf(
                "http://10.0.0.9:8060/query/apps",
                "http://10.0.0.9:8060/input/15985?t=v&u=http%3A%2F%2Forigin%2Fv.mp4&k=%28null%29&videoName=Movie&videoFormat=mp4",
                "http://10.0.0.9:8060/keypress/Pause",
                "http://10.0.0.9:8060/keypress/Home",
            ),
            urls,
        )
        assertNull(CastDispatcher.activeTarget(), "stopActive must end the session")
        assertFalse(port.active)
    }

    @Test
    fun stopActiveClearsSessionEvenWhenDeviceUnreachable() {
        var requestCount = 0
        val engine = MockEngine {
            requestCount++
            if (requestCount <= 2) {
                respond("<ok/>", HttpStatusCode.OK)
            } else {
                respond("gone", HttpStatusCode.ServiceUnavailable)
            }
        }
        val client = HttpClient(engine)
        val target = CastTarget.Dlna(DlnaDevice("rc2", "http://10.0.0.9/rootDesc.xml", "TV", "http://10.0.0.9/ctl"))

        runBlocking { CastDispatcher.cast(target, "http://origin/v.mp4", "Movie", client) }
        assertTrue(port.active)
        assertFalse(runBlocking { CastDispatcher.stopActive(client) }, "device refused the Stop action")
        assertNull(CastDispatcher.activeTarget(), "session must end locally even when the stop fails")
        assertFalse(port.active)
    }

    @Test
    fun chromeFamilyDefaultsCannotRemoteControl() {
        val client = HttpClient(MockEngine { respond("", HttpStatusCode.OK) })
        val target = CastTarget.Chrome(ChromeDevice("c1", "10.0.0.9", 8009, "Chromecast"))
        runBlocking {
            assertFalse(ChromeAdapter.pause(target, client))
            assertFalse(ChromeAdapter.resume(target, client))
            assertFalse(ChromeAdapter.stop(target, client))
            assertFalse(ChromeAdapter.volumeUp(target, client))
            assertFalse(ChromeAdapter.volumeDown(target, client))
            assertFalse(ChromeAdapter.toggleMute(target, client))
        }
    }

    @Test
    fun clearedCastAttemptCannotCommit() {
        val session = CastSession()
        val target = CastTarget.Kodi(KodiDevice("epoch", "http://10.0.0.8:8080", "Kodi"))
        val staleAttempt = session.beginAttempt()

        session.clearActive()

        assertFalse(session.commitActive(target, staleAttempt))
        assertNull(session.activeTarget())
        val currentAttempt = session.beginAttempt()
        assertTrue(session.commitActive(target, currentAttempt))
        assertEquals(target, session.activeTarget())
    }

    @Test
    fun dlnaSoapFailureDoesNotActivateCast() {
        val engine = MockEngine {
            respond("", HttpStatusCode.InternalServerError)
        }
        val client = HttpClient(engine)
        val target = CastTarget.Dlna(DlnaDevice("u3", "http://10.0.0.9/rootDesc.xml", "TV", "http://10.0.0.9/ctl"))

        val result = runBlocking { CastDispatcher.cast(target, "http://origin/v.mp4", "Movie", client) }

        assertEquals("DLNA rejected the URL", result.message)
        assertNull(CastDispatcher.activeTarget())
        assertFalse(port.active)
    }


    @Test
    fun dlnaPlayNonSuccessResponseDoesNotActivateCast() {
        var requestCount = 0
        val engine = MockEngine {
            requestCount++
            if (requestCount == 1) {
                respond(
                    content = """<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/></s:Body></s:Envelope>""",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/xml"),
                )
            } else {
                respond("<error>Play failed</error>", HttpStatusCode.InternalServerError)
            }
        }
        val client = HttpClient(engine)
        val target = CastTarget.Dlna(DlnaDevice("u5", "http://10.0.0.9/rootDesc.xml", "TV", "http://10.0.0.9/ctl"))

        val result = runBlocking { CastDispatcher.cast(target, "http://origin/v.mp4", "Movie", client) }

        assertEquals("DLNA rejected the URL", result.message)
        assertNull(CastDispatcher.activeTarget())
        assertEquals(2, engine.requestHistory.size)
    }

    @Test
    fun kodiSeekWithUnknownDurationIsNotDispatched() {
        val engine = MockEngine {
            respond(
                content = """{"jsonrpc":"2.0","id":1,"result":"OK"}""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "application/json"),
            )
        }
        val client = HttpClient(engine)
        val target = CastTarget.Kodi(KodiDevice("k3", "http://10.0.0.7:8080", "Kodi"))

        runBlocking { CastDispatcher.cast(target, "http://origin/v.mp4", "Movie", client) }
        assertFalse(runBlocking { CastDispatcher.seekActive(30_000, 0, client) })
        assertEquals(1, engine.requestHistory.size)
    }
    @Test
    fun recastSkipsInactiveTargetAndVoidedAttemptCannotCommit() {
        val engine = MockEngine {
            respond(
                content = """<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/></s:Body></s:Envelope>""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/xml"),
            )
        }
        val client = HttpClient(engine)
        val target = CastTarget.Dlna(DlnaDevice("u4", "http://10.0.0.9/rootDesc.xml", "TV", "http://10.0.0.9/ctl"))

        // Never activated: recast must refuse to dispatch entirely.
        assertNull(runBlocking { CastDispatcher.recastIfActive(target, "http://origin/v.mp4", "Movie", client) })
        assertEquals(0, engine.requestHistory.size)

        // Activated then cleared: the in-flight attempt's commit is voided.
        val session = CastSession()
        assertTrue(session.commitActive(target, session.beginAttempt()))
        val inFlightAttempt = session.beginAttemptFor(target)
        session.clearActive()
        assertNotNull(inFlightAttempt)
        assertFalse(session.commitActive(target, inFlightAttempt))
        assertNull(session.activeTarget())
    }
    @Test
    fun stopActiveReturnsRemoteResultAfterLocalTeardown() {
        val engine = MockEngine { request ->
            if (request.headers["SOAPACTION"]?.contains("#Stop") == true) {
                respond("", HttpStatusCode.InternalServerError)
            } else {
                respond(
                    content = "<ok/>",
                    status = HttpStatusCode.OK,
                    headers = headersOf(HttpHeaders.ContentType, "text/xml"),
                )
            }
        }
        val client = HttpClient(engine)
        val target = CastTarget.Dlna(DlnaDevice("stop-1", "http://10.0.0.9/rootDesc.xml", "TV", "http://10.0.0.9/ctl"))

        assertTrue(runBlocking { CastDispatcher.cast(target, "http://origin/v.mp4", "Movie", client) } is CastResult.Sent)
        val stopped = runBlocking { CastDispatcher.stopActive(client) }

        assertFalse(stopped)
        assertTrue(port.stopRequested)
        assertNull(CastDispatcher.activeTarget())
    }
    @Test
    fun dlnaPositionIsReturnedInMilliseconds() {
        val engine = MockEngine {
            respond(
                content = """<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><TrackDuration>00:10:05.678</TrackDuration><RelTime>00:01:02.345</RelTime></u:GetPositionInfoResponse></s:Body></s:Envelope>""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "text/xml"),
            )
        }
        val client = HttpClient(engine)
        val target = CastTarget.Dlna(DlnaDevice("position-dlna", "http://10.0.0.9/rootDesc.xml", "TV", "http://10.0.0.9/ctl"))

        assertEquals(62_345L, runBlocking { CastDispatcher.position(target, client) })
        assertEquals(1, engine.requestHistory.size)
        assertTrue(engine.requestHistory.single().headers["SOAPACTION"]!!.contains("#GetPositionInfo"))
    }

    @Test
    fun kodiPositionIsReturnedInMilliseconds() {
        val engine = MockEngine {
            respond(
                content = """{"jsonrpc":"2.0","id":1,"result":{"time":{"hours":0,"minutes":1,"seconds":2,"milliseconds":345},"totaltime":{"hours":0,"minutes":10,"seconds":5,"milliseconds":678}}}""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "application/json"),
            )
        }
        val client = HttpClient(engine)
        val target = CastTarget.Kodi(KodiDevice("position-kodi", "http://10.0.0.7:8080", "Kodi"))

        assertEquals(62_345L, runBlocking { CastDispatcher.position(target, client) })
        assertEquals("http://10.0.0.7:8080/jsonrpc", engine.requestHistory.single().url.toString())
    }

    @Test
    fun positionReturnsNullForUnsupportedReceiver() {
        val engine = MockEngine { respond("unexpected", HttpStatusCode.OK) }
        val client = HttpClient(engine)
        val target = CastTarget.Roku(RokuDevice("position-roku", "http://10.0.0.8:8060/", "Roku"))

        assertNull(runBlocking { CastDispatcher.position(target, client) })
        assertEquals(0, engine.requestHistory.size)
    }
    @Test
    fun positionActiveDoesNotSupersedeAnInFlightCast() = runTest {
        val positionResponse = """{"jsonrpc":"2.0","id":1,"result":{"time":{"hours":0,"minutes":1,"seconds":2,"milliseconds":345},"totaltime":{"hours":0,"minutes":10,"seconds":5,"milliseconds":678}}}"""
        val castStarted = CompletableDeferred<Unit>()
        var delayCast = false
        val engine = MockEngine { request ->
            val body = (request.body as? TextContent)?.text.orEmpty()
            if (body.contains("Player.Open")) {
                if (delayCast) {
                    castStarted.complete(Unit)
                    delay(1_000)
                }
                respond("""{"jsonrpc":"2.0","id":1,"result":"OK"}""", HttpStatusCode.OK)
            } else {
                respond(positionResponse, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
            }
        }
        val client = HttpClient(engine)
        val target = CastTarget.Kodi(KodiDevice("active-position", "http://10.0.0.7:8080", "Kodi"))

        assertNull(CastDispatcher.positionActive(client))
        assertTrue(CastDispatcher.cast(target, "http://origin/v.mp4", "Movie", client) is CastResult.Sent)
        delayCast = true
        val inFlight = async { CastDispatcher.cast(target, "http://origin/recast.mp4", "Recast", client) }
        castStarted.await()

        assertEquals(62_345L, CastDispatcher.positionActive(client))
        assertTrue(inFlight.await() is CastResult.Sent)
        assertEquals(target, CastDispatcher.activeTarget())
    }

    @Test
    fun delayedPositionQueryIsDiscardedAfterDetach() = runTest {
        val started = CompletableDeferred<Unit>()
        val positionResponse = """{"jsonrpc":"2.0","id":1,"result":{"time":{"hours":0,"minutes":1,"seconds":2,"milliseconds":345},"totaltime":{"hours":0,"minutes":10,"seconds":5,"milliseconds":678}}}"""
        val engine = MockEngine { request ->
            val body = (request.body as? TextContent)?.text.orEmpty()
            if (body.contains("Player.GetProperties")) {
                started.complete(Unit)
                delay(1_000)
                respond(positionResponse, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
            } else {
                respond("""{"jsonrpc":"2.0","id":1,"result":"OK"}""", HttpStatusCode.OK)
            }
        }
        val client = HttpClient(engine)
        val target = CastTarget.Kodi(KodiDevice("detach-position", "http://10.0.0.7:8080", "Kodi"))

        assertTrue(CastDispatcher.cast(target, "http://origin/v.mp4", "Movie", client) is CastResult.Sent)
        val query = async { CastDispatcher.positionActive(client) }
        started.await()
        assertEquals(target, CastDispatcher.detachActive())
        assertNull(query.await())
        assertNull(CastDispatcher.activeTarget())
    }

    @Test
    fun delayedPositionQueryIsDiscardedAfterNewCast() = runTest {
        val started = CompletableDeferred<Unit>()
        val positionResponse = """{"jsonrpc":"2.0","id":1,"result":{"time":{"hours":0,"minutes":1,"seconds":2,"milliseconds":345},"totaltime":{"hours":0,"minutes":10,"seconds":5,"milliseconds":678}}}"""
        val engine = MockEngine { request ->
            val body = (request.body as? TextContent)?.text.orEmpty()
            if (body.contains("Player.GetProperties")) {
                started.complete(Unit)
                delay(1_000)
                respond(positionResponse, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))
            } else {
                respond("""{"jsonrpc":"2.0","id":1,"result":"OK"}""", HttpStatusCode.OK)
            }
        }
        val client = HttpClient(engine)
        val first = CastTarget.Kodi(KodiDevice("old-position", "http://10.0.0.7:8080", "Kodi"))
        val replacement = CastTarget.Kodi(KodiDevice("new-position", "http://10.0.0.8:8080", "Kodi"))

        assertTrue(CastDispatcher.cast(first, "http://origin/old.mp4", "Old", client) is CastResult.Sent)
        val query = async { CastDispatcher.positionActive(client) }
        started.await()
        assertTrue(CastDispatcher.cast(replacement, "http://origin/new.mp4", "New", client) is CastResult.Sent)
        assertNull(query.await())
        assertEquals(replacement, CastDispatcher.activeTarget())
    }

    @Test
    fun supersededCastReturnsRejectedRatherThanSent() = runTest {
        val firstStarted = CompletableDeferred<Unit>()
        val engine = MockEngine { request ->
            if (request.url.toString().contains("10.0.0.1")) {
                firstStarted.complete(Unit)
                delay(1_000)
            }
            respond("""{"jsonrpc":"2.0","id":1,"result":"OK"}""", HttpStatusCode.OK)
        }
        val client = HttpClient(engine)
        val firstTarget = CastTarget.Kodi(KodiDevice("superseded-first", "http://10.0.0.1:8080", "Kodi 1"))
        val secondTarget = CastTarget.Kodi(KodiDevice("superseding-second", "http://10.0.0.2:8080", "Kodi 2"))

        val stale = async { CastDispatcher.cast(firstTarget, "http://origin/first.mp4", "First", client) }
        firstStarted.await()
        val current = CastDispatcher.cast(secondTarget, "http://origin/second.mp4", "Second", client)

        assertTrue(current is CastResult.Sent)
        assertTrue(stale.await() is CastResult.Rejected)
        assertEquals(secondTarget, CastDispatcher.activeTarget())
    }

    @Test
    fun supersededRecastReturnsRejectedRatherThanSent() = runTest {
        var delayFirst = false
        val recastStarted = CompletableDeferred<Unit>()
        val engine = MockEngine { request ->
            if (delayFirst && request.url.toString().contains("10.0.0.1")) {
                recastStarted.complete(Unit)
                delay(1_000)
            }
            respond("""{"jsonrpc":"2.0","id":1,"result":"OK"}""", HttpStatusCode.OK)
        }
        val client = HttpClient(engine)
        val active = CastTarget.Kodi(KodiDevice("recast-first", "http://10.0.0.1:8080", "Kodi 1"))
        val replacement = CastTarget.Kodi(KodiDevice("recast-second", "http://10.0.0.2:8080", "Kodi 2"))

        assertTrue(CastDispatcher.cast(active, "http://origin/first.mp4", "First", client) is CastResult.Sent)
        delayFirst = true
        val stale = async { CastDispatcher.recastIfActive(active, "http://origin/recast.mp4", "Recast", client) }
        recastStarted.await()
        val current = CastDispatcher.cast(replacement, "http://origin/second.mp4", "Second", client)
        val staleResult = stale.await()

        assertTrue(current is CastResult.Sent)
        assertNotNull(staleResult)
        assertTrue(staleResult is CastResult.Rejected)
        assertEquals(replacement, CastDispatcher.activeTarget())
    }
}
