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
}
