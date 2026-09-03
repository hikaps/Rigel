package app.rigel.player

import app.rigel.bridge.HttpServerBridge
import app.rigel.bridge.ProbeBridge
import app.rigel.bridge.ProbeResult
import app.rigel.bridge.RigelBridgeFactory
import app.rigel.bridge.TranscodeBridge
import app.rigel.bridge.SubtitleTrack

import app.rigel.gateway.PlaybackRoute
import app.rigel.intake.IntakeRequest
import app.rigel.settings.LinkHistoryEntry
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
        ProbeResult("mp4", "h264", listOf("aac"), emptyList(), 60_000, isLive = false, pixFmt = "yuv420p")
    private var probeError: String? = null
    private var hlsPath: String? = "hls/s1/out.m3u8"
    private var hlsError: String? = null
    private var serverPort: Long = 8090
    private var serverError: String? = null
    private var serverStopped = false
    private var lanBase: String? = null
    private val stoppedSessions = mutableListOf<String>()
    private val hlsModes = mutableListOf<String>()
    private val hlsOffsets = mutableListOf<Long>()
    private val hlsSessionIds = mutableListOf<String>()
    private val hlsSubtitleTracks = mutableListOf<List<SubtitleTrack>>()

    private var transcodeErrorCallback: ((String) -> Unit)? = null
    /** When non-null, startHlsSession defers its onReady until fired here. */
    private var pendingReady: ((String?, String?) -> Unit)? = null

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
                    startOffsetMs: Long,
                    subtitleTracks: List<SubtitleTrack>,
                    onReady: (String?, String?) -> Unit,
                    onError: (String) -> Unit,
                ) {
                    hlsModes += mode
                    hlsOffsets += startOffsetMs
                    hlsSessionIds += sessionId
                    hlsSubtitleTracks += subtitleTracks
                    transcodeErrorCallback = onError
                    if (pendingReady != null) {
                        pendingReady = onReady
                    } else {
                        onReady(hlsPath, hlsError)
                    }
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
        subtitleTracks = emptyList(),
        successCallbackUrl = null,
    )


    @BeforeTest
    fun setUp() {
        // Tests mutate the fixture fields; reset so order can't leak state.
        resetFixtures()
        Dispatchers.setMain(dispatcher)
    }

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
        RigelBridgeFactory.register(discovery = null, probe = null, transcode = null, httpServer = null)
    }

    private fun resetFixtures() {
        probeResult = ProbeResult("mp4", "h264", listOf("aac"), emptyList(), 60_000, isLive = false, pixFmt = "yuv420p")
        probeError = null
        hlsPath = "hls/s1/out.m3u8"
        hlsError = null
        serverPort = 8090
        serverError = null
        serverStopped = false
        lanBase = null
        stoppedSessions.clear()
        hlsModes.clear()
        hlsOffsets.clear()
        hlsSessionIds.clear()
        hlsSubtitleTracks.clear()
        transcodeErrorCallback = null
        pendingReady = null
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
    fun loadRawRecordsLinkInHistory() {
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        val c = controller(settings)
        assertTrue(c.loadRaw("http://h/v.mp4"))
        assertEquals(
            listOf(LinkHistoryEntry("http://h/v.mp4", null)),
            settings.linkHistory(),
        )
    }

    @Test
    fun loadRawWithTitleRecordsTitle() {
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        val c = controller(settings)
        assertTrue(c.loadRaw("http://h/v.mp4", title = "My Movie"))
        assertEquals(
            listOf(LinkHistoryEntry("http://h/v.mp4", "My Movie")),
            settings.linkHistory(),
        )
    }

    @Test
    fun selectedSubtitleIsPassedToReplacementProxySession() = runTest(dispatcher.scheduler) {
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
        c.loadRequest(request)
        advanceUntilIdle()

        val track = SubtitleTrack("https://subtitles.example/movie.srt", "en", "English")
        c.selectExternalSubtitle(track, positionMs = 15_000)
        advanceUntilIdle()

        assertEquals(listOf(track), c.uiState.value.subtitleTracks)
        assertEquals(track.url, c.uiState.value.selectedExternalSubtitleUrl)
        assertEquals(listOf(track), hlsSubtitleTracks.last())
        assertEquals(15_000, hlsOffsets.last())
    }

    @Test
    fun selectingSubtitleOnDirectVideoStartsProxyAtRequestedPosition() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        val track = SubtitleTrack("https://subtitles.example/movie.srt", "en", "English")
        c.selectExternalSubtitle(track, positionMs = 120_000)
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.REMUX, c.uiState.value.route)
        assertEquals(60_000, hlsOffsets.last())
        assertEquals(listOf(track), hlsSubtitleTracks.last())
    }

    @Test
    fun selectedSubtitleOverridesDirectRoutePreference() = runTest(dispatcher.scheduler) {
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "DIRECT")))
        val c = controller(settings)
        val track = SubtitleTrack("https://subtitles.example/movie.srt", "en", "English")
        c.loadRequest(request.copy(subtitleTracks = listOf(track)))
        advanceUntilIdle()

        assertEquals(PlaybackRoute.REMUX, c.uiState.value.route)
        assertEquals(listOf(track), hlsSubtitleTracks.last())
    }

    @Test
    fun clearingSelectedSubtitleLocallyRebuildsWithoutSidecar() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        val track = SubtitleTrack("https://subtitles.example/movie.srt", "en", "English")
        c.selectExternalSubtitle(track, positionMs = 15_000)
        advanceUntilIdle()

        c.selectExternalSubtitle(null, positionMs = 30_000)
        advanceUntilIdle()

        assertNull(c.uiState.value.selectedExternalSubtitleUrl)
        assertEquals(listOf(track), c.uiState.value.subtitleTracks)
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertNotNull(c.uiState.value.proxyUrl)
        assertTrue(hlsSubtitleTracks.last().isEmpty())
        assertEquals(30_000, hlsOffsets.last())

        // A second Off is a state-only no-op: the live session has no sidecar.
        val sessionCount = hlsSessionIds.size
        c.selectExternalSubtitle(null, positionMs = 0)
        advanceUntilIdle()
        assertEquals(sessionCount, hlsSessionIds.size)
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
    }

    @Test
    fun clearingSubtitleWithoutSidecarSessionDoesNotRebuild() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult("mkv", "hevc", listOf("aac"), emptyList(), 60_000, isLive = false, pixFmt = "yuv420p")
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        assertNotNull(c.uiState.value.proxyUrl)
        assertTrue(hlsSubtitleTracks.last().isEmpty())
        val sessionCount = hlsSessionIds.size

        c.selectExternalSubtitle(null, positionMs = 0)
        advanceUntilIdle()

        assertEquals(sessionCount, hlsSessionIds.size)
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
    }

    @Test
    fun clearingSelectedSubtitleDuringCastRebuildsWithoutSidecar() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        val track = SubtitleTrack("https://subtitles.example/movie.srt", "en", "English")
        c.selectExternalSubtitle(track, positionMs = 15_000)
        advanceUntilIdle()
        c.setCastActive(true)

        c.selectExternalSubtitle(null, positionMs = 30_000)
        advanceUntilIdle()

        assertNull(c.uiState.value.selectedExternalSubtitleUrl)
        assertEquals(listOf(track), c.uiState.value.subtitleTracks)
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertNotNull(c.uiState.value.proxyUrl)
        assertTrue(hlsSubtitleTracks.last().isEmpty())
        assertEquals(30_000, hlsOffsets.last())
    }

    @Test
    fun selectingSameExternalSubtitleRebuildsWithoutDuplicatingTrack() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        val track = SubtitleTrack("https://subtitles.example/movie.srt", "en", "English")
        c.selectExternalSubtitle(track, positionMs = 15_000)
        advanceUntilIdle()
        val sessionCount = hlsSessionIds.size

        c.selectExternalSubtitle(track, positionMs = 30_000)
        advanceUntilIdle()

        assertEquals(listOf(track), c.uiState.value.subtitleTracks)
        assertEquals(sessionCount + 1, hlsSessionIds.size)
        assertEquals(30_000, hlsOffsets.last())
    }

    @Test
    fun audioOnlyExternalSubtitleDoesNotStartCaptionProxy() = runTest(dispatcher.scheduler) {
        val originalProbe = probeResult
        probeResult = ProbeResult(
            "mp4",
            null,
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = null,
        )
        try {
            val c = controller()
            c.loadRequest(request)
            advanceUntilIdle()
            val sessionCount = hlsSessionIds.size
            val track = SubtitleTrack("https://subtitles.example/audio.srt", "en", "English")

            c.selectExternalSubtitle(track, positionMs = 15_000)

            assertEquals(track.url, c.uiState.value.selectedExternalSubtitleUrl)
            assertEquals(listOf(track), c.uiState.value.subtitleTracks)
            assertEquals(sessionCount, hlsSessionIds.size)
        } finally {
            probeResult = originalProbe
        }
    }

    @Test
    fun rejectedUrlNotRecorded() {
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        val c = controller(settings)
        assertFalse(c.loadRaw("not a url"))
        assertTrue(settings.linkHistory().isEmpty())
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
    fun proxySeekRestartsSessionAtRequestedOffset() = runTest(dispatcher.scheduler) {
        hlsOffsets.clear()
        hlsSessionIds.clear()
        stoppedSessions.clear()
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(listOf(0L), hlsOffsets)
        val firstSession = hlsSessionIds.single()

        c.seek(45_000, 60_000)
        assertEquals(PlayerPhase.BUFFERING, c.uiState.value.phase)
        assertEquals("http://127.0.0.1:8090/hls/s1/out.m3u8", c.uiState.value.proxyUrl)
        c.reportError("stale proxy failure")
        assertEquals(PlayerPhase.BUFFERING, c.uiState.value.phase)
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(45_000L, c.uiState.value.startPositionMs)
        assertEquals(listOf(0L, 45_000L), hlsOffsets)
        assertEquals(2, hlsSessionIds.distinct().size)
        assertEquals(1, stoppedSessions.size)
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
    fun runtimeProxyErrorAfterReadySetsError() = runTest(dispatcher.scheduler) {
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)

        transcodeErrorCallback?.invoke("video format changed during transcode")
        advanceUntilIdle()
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals("video format changed during transcode", c.uiState.value.error)
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
    fun directFailureAutoFallsBackToTranscodeOnce() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        c.reportError("decoder failure")
        advanceUntilIdle()
        val state = c.uiState.value
        assertEquals(PlayerPhase.PLAYING, state.phase)
        assertEquals(PlaybackRoute.TRANSCODE, state.route)
        assertEquals("http://127.0.0.1:8090/hls/s1/out.m3u8", state.proxyUrl)
        assertEquals(listOf("transcode"), hlsModes)
    }

    @Test
    fun noSecondDemotionAfterFallback() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        c.reportError("first failure")
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)

        c.reportError("second failure")
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals("second failure", c.uiState.value.error)
    }

    @Test
    fun fallbackBudgetResetsOnNewLoad() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        c.reportError("first media failure")
        advanceUntilIdle()
        assertEquals(PlaybackRoute.TRANSCODE, c.uiState.value.route)

        c.stopPlayback()
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        c.reportError("fresh failure")
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.TRANSCODE, c.uiState.value.route)
    }

    @Test
    fun reportErrorSetsErrorState() {
        val c = controller()
        c.reportError("boom")
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals("boom", c.uiState.value.error)
    }

    @Test
    fun externalSubtitleTracksForceRemux() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request.copy(subtitleTracks = listOf(SubtitleTrack("https://cdn.h/subs.ass"))))
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(
            listOf(listOf(SubtitleTrack("https://cdn.h/subs.ass"))),
            hlsSubtitleTracks,
        )
        assertEquals(PlaybackRoute.REMUX, c.uiState.value.route)
        assertNotNull(c.uiState.value.proxyUrl)
        assertEquals(listOf("remux"), hlsModes)
    }

    @Test
    fun externalSubtitleWithQueryAndFragmentForcesRemux() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request.copy(subtitleTracks = listOf(SubtitleTrack("https://cdn.h/subs.ass?token=abc#track1"))))
        advanceUntilIdle()
        assertEquals(PlaybackRoute.REMUX, c.uiState.value.route)
    }
    @Test
    fun stoppingDuringProxyPreparationInvalidatesLateCallback() = runTest(dispatcher.scheduler) {
        pendingReady = { _, _ -> }
        val c = controller()
        c.loadRequest(request.copy(sourceUrl = "http://h/slow.mkv"))
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        c.reportError("decoder failure")
        advanceUntilIdle()
        assertEquals(PlayerPhase.PREPARING_PROXY, c.uiState.value.phase)
        assertTrue(stoppedSessions.isEmpty())

        c.stopPlayback()
        assertEquals(PlayerUiState(), c.uiState.value)
        assertTrue(stoppedSessions.isNotEmpty(), "pending HLS session must be stopped")

        pendingReady?.invoke(hlsPath, hlsError)
        advanceUntilIdle()
        assertEquals(PlayerUiState(), c.uiState.value)
        pendingReady = null
    }

    @Test
    fun oldProxyCallbackCannotOverwriteNewLoad() = runTest(dispatcher.scheduler) {
        pendingReady = { _, _ -> }
        val c = controller()
        c.loadRequest(request.copy(sourceUrl = "http://h/old.mkv"))
        advanceUntilIdle()
        c.reportError("old direct failure")
        advanceUntilIdle()
        assertEquals(PlayerPhase.PREPARING_PROXY, c.uiState.value.phase)

        c.loadRequest(request.copy(sourceUrl = "http://h/new.mp4"))
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals("http://h/new.mp4", c.uiState.value.sourceUrl)
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        pendingReady?.invoke(hlsPath, hlsError)
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals("http://h/new.mp4", c.uiState.value.sourceUrl)
        assertNull(c.uiState.value.proxyUrl)
        pendingReady = null
    }

    @Test
    fun percentEncodedExternalSubtitleForcesRemux() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request.copy(subtitleTracks = listOf(SubtitleTrack("https://cdn.h/sub%2Eass"))))
        advanceUntilIdle()
        assertEquals(PlaybackRoute.REMUX, c.uiState.value.route)
    }

    @Test
    fun mixedCaseExternalSubtitleForcesRemux() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request.copy(subtitleTracks = listOf(SubtitleTrack("https://cdn.h/SUBS.ASS"))))
        advanceUntilIdle()
        assertEquals(PlaybackRoute.REMUX, c.uiState.value.route)
    }

    @Test
    fun externalSrtSubtitleForcesRemux() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request.copy(subtitleTracks = listOf(SubtitleTrack("https://cdn.h/assets/subtitles.srt"))))
        advanceUntilIdle()
        assertEquals(PlaybackRoute.REMUX, c.uiState.value.route)
        assertNotNull(c.uiState.value.proxyUrl)
    }

    @Test
    fun errorDuringProxyPrepIsSwallowed() = runTest(dispatcher.scheduler) {
        pendingReady = { _, _ -> }
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        c.reportError("first failure")
        advanceUntilIdle()
        // Fallback in flight; proxy onReady not yet fired.
        assertEquals(PlayerPhase.PREPARING_PROXY, c.uiState.value.phase)

        // Native player's duplicate `.failed` poll races the proxy build.
        c.reportError("duplicate failure from dying player")
        assertEquals(PlayerPhase.PREPARING_PROXY, c.uiState.value.phase)
        assertNull(c.uiState.value.error)

        pendingReady?.invoke(hlsPath, hlsError)
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.TRANSCODE, c.uiState.value.route)
        assertNotNull(c.uiState.value.proxyUrl)
        pendingReady = null
    }
}
