package app.rigel.player

import app.rigel.bridge.HttpServerBridge
import app.rigel.bridge.ProbeBridge
import app.rigel.bridge.ProbeResult
import app.rigel.bridge.RigelBridgeFactory
import app.rigel.bridge.TranscodeBridge
import app.rigel.gateway.PlaybackRoute
import app.rigel.intake.IntakeRequest
import app.rigel.settings.RouteOverride
import app.rigel.settings.SettingsStore
import com.russhwolf.settings.MapSettings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class PlayerControllerTest {

    private val dispatcher = StandardTestDispatcher()

    private var probeResult: ProbeResult? =
        ProbeResult("mp4", "h264", listOf("aac"), emptyList(), 60_000, isLive = false)
    private var probeError: String? = null
    private var hlsPath: String? = "hls/s1/out.m3u8"
    private var hlsError: String? = null
    private var serverPort: Long = 8090
    private var serverError: String? = null
    private var lanBase: String? = null
    private val stoppedSessions = mutableListOf<String>()
    private var serverStopped = false
    private val hlsModes = mutableListOf<String>()

    private fun controller(settings: SettingsStore = SettingsStore(MapSettings(mutableMapOf()))): PlayerController {
        RigelBridgeFactory.register(
            discovery = null,
            probe = object : ProbeBridge {
                override fun probe(url: String, headers: Map<String, String>, onResult: (ProbeResult?, String?) -> Unit) {
                    onResult(probeResult, probeError)
                }
            },
            transcode = object : TranscodeBridge {
                override fun startHlsSession(
                    sessionId: String,
                    sourceUrl: String,
                    headers: Map<String, String>,
                    mode: String,
                    onReady: (String?, String?) -> Unit,
                ) {
                    hlsModes += mode
                    onReady(hlsPath, hlsError)
                }

                override fun stopHlsSession(sessionId: String) {
                    stoppedSessions += sessionId
                }
            },
            httpServer = object : HttpServerBridge {
                override fun start(onStarted: (Long, String?) -> Unit) = onStarted(serverPort, serverError)
                override fun stop() {
                    serverStopped = true
                }

                override fun lanBaseUrl(): String? = lanBase
            },
        )
        return PlayerController(settings)
    }

    private val request = IntakeRequest(
        sourceUrl = "http://h/v.mp4",
        filename = "v.mp4",
        subtitleUrls = emptyList(),
        successCallbackUrl = null,
    )

    @BeforeTest
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun loadRawRejectsUnrecognizedUrl() {
        val c = controller()
        val accepted = c.loadRaw("not a url")
        assertFalse(accepted)
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertTrue(c.uiState.value.error!!.contains("Unrecognized URL"))
    }

    @Test
    fun loadRawAcceptsValidUrl() {
        val c = controller()
        val accepted = c.loadRaw("http://h/v.mp4")
        assertTrue(accepted)
        assertEquals(PlayerPhase.PROBING, c.uiState.value.phase)
    }

    @Test
    fun directRouteWhenAutoOverride() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        val state = c.uiState.value
        assertEquals(PlayerPhase.PLAYING, state.phase)
        assertEquals(PlaybackRoute.DIRECT, state.route)
        assertNull(state.proxyUrl)
        assertNotNull(state.probe)
        assertEquals("v.mp4", state.filename)
        assertEquals("http://h/v.mp4", state.sourceUrl)
    }

    @Test
    fun alwaysProxyOverrideForcesRemux() = runTest(dispatcher.scheduler) {
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
        c.loadRequest(request)
        advanceUntilIdle()
        val state = c.uiState.value
        assertEquals(PlayerPhase.PLAYING, state.phase)
        assertEquals("http://127.0.0.1:8090/hls/s1/out.m3u8", state.proxyUrl)
        assertEquals(listOf("remux"), hlsModes)
    }

    @Test
    fun proxyUrlUsesLanBaseWhenAvailable() = runTest(dispatcher.scheduler) {
        lanBase = "http://192.168.1.50:8090"
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
        c.loadRequest(request)
        advanceUntilIdle()
        val state = c.uiState.value
        assertEquals(PlayerPhase.PLAYING, state.phase)
        // AirPlay remote playback: the TV fetches the playlist itself, so the
        // proxy URL must be LAN-reachable, not loopback.
        assertEquals("http://192.168.1.50:8090/hls/s1/out.m3u8", state.proxyUrl)
    }

    @Test
    fun directOverrideSkipsProxy() = runTest(dispatcher.scheduler) {
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "DIRECT")))
        val c = controller(settings)
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
        assertNull(c.uiState.value.proxyUrl)
        assertTrue(hlsModes.isEmpty())
    }

    @Test
    fun probeFailureSetsErrorState() = runTest(dispatcher.scheduler) {
        probeResult = null
        probeError = "ffprobe died"
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals("ffprobe died", c.uiState.value.error)
    }

    @Test
    fun transcodeFailureSetsErrorState() = runTest(dispatcher.scheduler) {
        hlsPath = null
        hlsError = "ffmpeg failed"
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals("ffmpeg failed", c.uiState.value.error)
    }

    @Test
    fun httpServerFailureSetsErrorAndStopsSession() = runTest(dispatcher.scheduler) {
        serverPort = -1
        serverError = "bind failed"
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals("bind failed", c.uiState.value.error)
        assertEquals(1, stoppedSessions.size)
    }

    @Test
    fun retryWithProxyReprobesAndBuildsProxy() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        c.retryWithProxy()
        advanceUntilIdle()
        val state = c.uiState.value
        assertEquals(PlayerPhase.PLAYING, state.phase)
        assertEquals(PlaybackRoute.REMUX, state.route)
        assertEquals("http://127.0.0.1:8090/hls/s1/out.m3u8", state.proxyUrl)
        assertEquals(listOf("remux"), hlsModes)
    }

    @Test
    fun stopPlaybackResetsStateAndStopsServer() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        c.stopPlayback()
        assertEquals(PlayerUiState(), c.uiState.value)
        assertTrue(serverStopped)
    }

    @Test
    fun reportErrorSetsErrorState() {
        val c = controller()
        c.reportError("boom")
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals("boom", c.uiState.value.error)
    }
}
