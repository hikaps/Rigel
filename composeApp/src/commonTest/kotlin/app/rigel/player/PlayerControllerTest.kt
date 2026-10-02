package app.rigel.player

import app.rigel.bridge.HttpServerBridge
import app.rigel.bridge.ProbeBridge
import app.rigel.bridge.ProbeOperation
import app.rigel.bridge.ProbeResult
import app.rigel.bridge.RigelBridgeFactory
import app.rigel.bridge.TranscodeBridge
import app.rigel.bridge.SubtitleTrack
import app.rigel.cast.CastDispatcher
import app.rigel.cast.CastTarget
import app.rigel.cast.DlnaDevice
import app.rigel.cast.RokuDevice

import app.rigel.gateway.PlaybackRoute
import app.rigel.output.OutputCapabilityResolver
import app.rigel.output.OutputMediaProfile
import app.rigel.output.OutputMediaProfiles
import app.rigel.output.PlaybackDestination
import app.rigel.output.OutputSelection
import app.rigel.intake.IntakeRequest
import app.rigel.intake.JellyfinPlaybackContext
import app.rigel.settings.LinkHistoryEntry
import app.rigel.settings.RouteOverride
import app.rigel.settings.SettingsStore
import app.rigel.settings.JellyfinTokenStore
import app.rigel.source.jellyfin.JellyfinApi
import app.rigel.source.jellyfin.JellyfinClient
import app.rigel.source.jellyfin.JellyfinSession
import com.russhwolf.settings.MapSettings
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.TextContent
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
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
    private val probeUrls = mutableListOf<String>()
    private var deferProbe = false
    private var pendingProbe: ((ProbeResult?, String?) -> Unit)? = null
    private val stoppedSessions = mutableListOf<String>()
    private val hlsModes = mutableListOf<String>()
    private val hlsPassthroughAudioCodecs = mutableListOf<List<String>>()
    private val hlsOffsets = mutableListOf<Long>()
    private val hlsSessionIds = mutableListOf<String>()
    private val hlsSubtitleTracks = mutableListOf<List<SubtitleTrack>>()

    private var transcodeErrorCallback: ((String) -> Unit)? = null
    /** When non-null, startHlsSession defers its onReady until fired here. */
    private var pendingReady: ((String?, String?) -> Unit)? = null

    private fun controller(
        settings: SettingsStore = SettingsStore(MapSettings(mutableMapOf())),
        jellyfin: JellyfinClient? = null,
        onSuccess: (String) -> Unit = {},
        capabilityResolver: OutputCapabilityResolver = app.rigel.output.DefaultOutputCapabilityResolver,
    ): PlayerController {
        RigelBridgeFactory.register(
            discovery = null,
            probe = object : ProbeBridge {
                override fun probe(url: String, headers: Map<String, String>, onResult: (ProbeResult?, String?) -> Unit): ProbeOperation {
                    probeUrls += url
                    if (deferProbe) pendingProbe = onResult else onResult(probeResult, probeError)
                    return object : ProbeOperation {
                        override fun cancel() = Unit
                    }
                }
            },
            transcode = object : TranscodeBridge {
                override fun startHlsSession(
                    sessionId: String,
                    sourceUrl: String,
                    headers: Map<String, String>,
                    mode: String,
                    passthroughAudioCodecs: List<String>,
                    startOffsetMs: Long,
                    subtitleTracks: List<SubtitleTrack>,
                    waitForCompletion: Boolean,
                    onReady: (String?, String?) -> Unit,
                    onError: (String) -> Unit,
                ) {
                    hlsModes += mode
                    hlsPassthroughAudioCodecs += passthroughAudioCodecs
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
        return PlayerController(settings, capabilityResolver = capabilityResolver, jellyfin = jellyfin, fireSuccess = onSuccess)
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
        CastDispatcher.clearActive()
        CastDispatcher.install(null, null)
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
        probeUrls.clear()
        deferProbe = false
        pendingProbe = null
        stoppedSessions.clear()
        hlsModes.clear()
        hlsPassthroughAudioCodecs.clear()
        hlsOffsets.clear()
        hlsSessionIds.clear()
        hlsSubtitleTracks.clear()
        transcodeErrorCallback = null
        pendingReady = null
    }
    private fun jellyfinSettings(base: String, token: String, userId: String): SettingsStore =
        SettingsStore(MapSettings(mutableMapOf())).also {
            it.setJellyfinServer(base)
            it.setJellyfinToken(token)
            it.setJellyfinUserId(userId)
        }

    private fun jellyfinPlaybackResponse(
        sessionId: String,
        sourceId: String,
        url: String = "/Videos/item1/master.m3u8?PlaySessionId=$sessionId&MediaSourceId=$sourceId",
        mediaStreams: String = "[]",
    ): String = """{"PlaySessionId":"$sessionId","MediaSources":[{"Id":"$sourceId","SupportsDirectPlay":false,"SupportsDirectStream":false,"SupportsTranscoding":true,"TranscodingUrl":"$url","MediaStreams":$mediaStreams}]}"""

    private fun jellyfinPlaybackClient(
        sessionId: String = "play-session-1",
        sourceId: String = "source-1",
        url: String = "/Videos/item1/master.m3u8?PlaySessionId=$sessionId&MediaSourceId=$sourceId",
        mediaStreams: String = "[]",
        requests: MutableList<String>? = null,
        playbackGate: CompletableDeferred<Unit>? = null,
        playbackStatus: HttpStatusCode = HttpStatusCode.OK,
    ): JellyfinClient = JellyfinClient(HttpClient(MockEngine) {
        engine {
            dispatcher = this@PlayerControllerTest.dispatcher
            addHandler { request ->
                requests?.add("${request.method.value} ${request.url}")
                if (request.url.toString().contains("/PlaybackInfo")) {
                    playbackGate?.await()
                    val body = if (playbackStatus == HttpStatusCode.OK) {
                        jellyfinPlaybackResponse(sessionId, sourceId, url, mediaStreams)
                    } else {
                        ""
                    }
                    respond(body, playbackStatus)
                } else {
                    respond("", HttpStatusCode.NoContent)
                }
            }
        }
    })

    private fun jellyfinPlaybackClientForFreshDeliveries(requests: MutableList<String>): JellyfinClient {
        var deliveryNumber = 0
        return JellyfinClient(HttpClient(MockEngine) {
            engine {
                dispatcher = this@PlayerControllerTest.dispatcher
                addHandler { request ->
                    val requestUrl = request.url.toString()
                    requests += "${request.method.value} $requestUrl"
                    if (requestUrl.contains("/PlaybackInfo")) {
                        deliveryNumber += 1
                        val sessionId = "delivery-$deliveryNumber"
                        val sourceId = "version-1"
                        val streamUrl =
                            "/Videos/item1/master.m3u8?PlaySessionId=$sessionId&MediaSourceId=$sourceId"
                        respond(
                            jellyfinPlaybackResponse(sessionId, sourceId, streamUrl),
                            HttpStatusCode.OK,
                        )
                    } else {
                        respond("", HttpStatusCode.NoContent)
                    }
                }
            }
        })
    }

    private fun jellyfinItemRequest(
        base: String,
        token: String,
        userId: String,
        itemId: String,
        mediaSourceId: String? = null,
    ): IntakeRequest = IntakeRequest(
        sourceUrl = JellyfinApi.itemDetailsUrl(base, userId, itemId),
        filename = null,
        subtitleTracks = emptyList(),
        successCallbackUrl = null,
        title = "Fixture title",
        jellyfinContext = JellyfinPlaybackContext(base, token, userId, itemId, mediaSourceId),
    )

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
    fun invalidLoadRawStopsActiveRemotePlayback() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        val actions = mutableListOf<String>()
        val engineDispatcher = dispatcher
        val client = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    actions += request.headers["SOAPACTION"] ?: request.url.toString()
                    respond("<ok/>", HttpStatusCode.OK)
                }
            }
        }
        val c = controller()
        val target = CastTarget.Dlna(
            DlnaDevice("invalid-load-1", "http://192.168.1.9/desc.xml", "Living Room", "http://192.168.1.9/control"),
        )
        val replacementTarget = CastTarget.Dlna(
            DlnaDevice("invalid-load-2", "http://192.168.1.10/desc.xml", "Bedroom", "http://192.168.1.10/control"),
        )
        CastDispatcher.install(c, client)
        try {
            c.loadRequest(request.copy(sourceUrl = "http://192.168.1.20/movie.mp4"), PlaybackDestination.Receiver(target))
            advanceUntilIdle()
            assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
            assertEquals(target, CastDispatcher.activeTarget())

            assertFalse(c.loadRaw("not a url"))
            assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
            advanceUntilIdle()

            assertNull(CastDispatcher.activeTarget())
            assertTrue(actions.any { it.contains("#Stop") }, "actions=$actions")

            val probesAfterInvalid = probeUrls.toList()
            val actionsAfterInvalid = actions.toList()
            c.selectReceiver(replacementTarget, positionMs = 0)
            advanceUntilIdle()

            assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
            assertTrue(c.uiState.value.error!!.contains("Unrecognized URL"))
            assertNull(c.uiState.value.sourceUrl)
            assertEquals(probesAfterInvalid, probeUrls)
            assertEquals(actionsAfterInvalid, actions)
        } finally {
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }

    @Test
    fun stoppingAfterInvalidLoadDoesNotFireSupersededSuccessCallback() = runTest(dispatcher.scheduler) {
        val callbacks = mutableListOf<String>()
        val c = controller(onSuccess = { callbacks += it })
        c.loadRequest(request.copy(successCallbackUrl = "https://callback.example/done"))
        advanceUntilIdle()

        assertFalse(c.loadRaw("not a url"))
        c.stopPlayback()
        advanceUntilIdle()

        assertTrue(callbacks.isEmpty())
    }

    @Test
    fun loadRawRecordsLinkInHistory() {
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        val c = controller(settings)
        assertTrue(c.loadRaw("http://h/v.mp4"))
        assertEquals(
            listOf(LinkHistoryEntry("http://h/v.mp4", "v.mp4")),
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
    fun selectingSubtitleOnDirectVideoKeepsDirectPlayback() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        val track = SubtitleTrack("https://subtitles.example/movie.srt", "en", "English")
        c.selectExternalSubtitle(track, positionMs = 120_000)
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
        assertNull(c.uiState.value.proxyUrl)
        assertEquals(listOf(track), c.uiState.value.subtitleTracks)
        assertEquals(track.url, c.uiState.value.selectedExternalSubtitleUrl)
        assertTrue(hlsSessionIds.isEmpty())
        assertTrue(hlsModes.isEmpty())

        c.selectExternalSubtitle(null, positionMs = 30_000)
        c.selectExternalSubtitle(track, positionMs = 45_000)
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
        assertEquals(track.url, c.uiState.value.selectedExternalSubtitleUrl)
        assertTrue(hlsSessionIds.isEmpty())
    }
    @Test
    fun selectedSubtitleSurvivesDirectFailureFallback() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()

        val track = SubtitleTrack("https://subtitles.example/movie.srt", "en", "English")
        c.selectExternalSubtitle(track, positionMs = 15_000)
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
        assertTrue(hlsSessionIds.isEmpty())

        c.reportError("decoder failure")
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.TRANSCODE, c.uiState.value.route)
        assertEquals(listOf(track), hlsSubtitleTracks.last())
        assertEquals(listOf("transcode"), hlsModes)
    }

    @Test
    fun selectedSubtitleDoesNotOverrideDirectRoutePreference() = runTest(dispatcher.scheduler) {
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "DIRECT")))
        val c = controller(settings)
        val track = SubtitleTrack("https://subtitles.example/movie.srt", "en", "English")
        c.loadRequest(request.copy(subtitleTracks = listOf(track)))
        advanceUntilIdle()

        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
        assertTrue(hlsModes.isEmpty())
    }

    @Test
    fun clearingSelectedSubtitleLocallyRebuildsWithoutSidecar() = runTest(dispatcher.scheduler) {
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
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
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
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
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
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
    fun directSeekPositionIsUsedByProxyFallback() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        c.seek(12_345, 60_000)
        assertEquals(12_345, c.uiState.value.startPositionMs)

        c.reportError("decoder failure")
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(12_345, hlsOffsets.single())
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
    fun initialExternalSubtitleKeepsDirectPlayback() = runTest(dispatcher.scheduler) {
        val track = SubtitleTrack("https://cdn.h/subs.ass")
        val c = controller()
        c.loadRequest(request.copy(subtitleTracks = listOf(track)))
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
        assertNull(c.uiState.value.proxyUrl)
        assertEquals(listOf(track), c.uiState.value.subtitleTracks)
        assertEquals(track.url, c.uiState.value.selectedExternalSubtitleUrl)
        assertTrue(hlsSessionIds.isEmpty())
        assertTrue(hlsModes.isEmpty())
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

    @Test
    fun proxyRebuildDuringCastKeepsRemoteTarget() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        val posted = mutableListOf<Pair<String, String?>>()
        val engineDispatcher = dispatcher
        val client = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    posted += request.url.toString() to ((request.body as? TextContent)?.text)
                    respond("", HttpStatusCode.OK)
                }
            }
        }
        lanBase = "http://192.168.1.50:8090"
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
        CastDispatcher.install(c, client)
        try {
            val target = CastTarget.Dlna(
                DlnaDevice("usn-1", "http://192.168.1.9/desc.xml", "Living Room", "http://192.168.1.9/control"),
            )
            c.loadRequest(request, PlaybackDestination.Receiver(target))
            advanceUntilIdle()
            assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase, "state=${c.uiState.value} hls=${hlsModes} posted=${posted}")
            assertTrue(c.uiState.value.remotePlayback)
            val castsAfterLoad = posted.count { it.first.contains("/control") }

            c.seek(45_000, 60_000)
            advanceUntilIdle()

            // The rebuild must re-derive the receiver and recast, not silently
            // switch this media to local iPhone playback.
            assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
            assertTrue(c.uiState.value.remotePlayback)
            assertTrue(c.uiState.value.castActive)
            assertTrue(posted.count { it.first.contains("/control") } > castsAfterLoad)
        } finally {
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }

    @Test
    fun replacementJellyfinPlayAwaitsPreviousSessionStop() = runTest(dispatcher.scheduler) {
        val jfBase = "http://jf:8096"
        val requests = mutableListOf<String>()
        val stopGate = CompletableDeferred<Unit>()
        val engineDispatcher = dispatcher
        val client = JellyfinClient(HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    val url = request.url.toString()
                    requests += url
                    if (url.endsWith("/Playing/Stop")) stopGate.await()
                    respond("", HttpStatusCode.NoContent)
                }
            }
        })
        val c = controller(jellyfinSettings(jfBase, "tok", "u1"), client)
        fun jfRequest(itemId: String): IntakeRequest {
            val sourceId = "version-$itemId"
            return request.copy(
                sourceUrl = "$jfBase/Videos/$itemId/stream?Static=true&MediaSourceId=$sourceId&api_key=tok",
                jellyfinContext = JellyfinPlaybackContext(jfBase, "tok", "u1", itemId, sourceId),
            )
        }
        fun jfTarget(sessionId: String) = PlaybackDestination.Receiver(
            CastTarget.JellyfinSessionTarget(JellyfinSession(sessionId, "TV", "Jellyfin Web", jfBase)),
        )

        c.loadRequest(jfRequest("i1"), jfTarget("s1"))
        advanceUntilIdle()
        assertEquals(listOf("$jfBase/Sessions/s1/Playing?playCommand=PlayNow&itemIds=i1&startPositionTicks=0&mediaSourceId=version-i1"), requests)

        c.loadRequest(jfRequest("i2"), jfTarget("s2"))
        advanceUntilIdle()
        // The old session's stop is still in flight; the replacement play must
        // not have been issued yet, or the late stop would kill the new item.
        assertTrue(requests.none { it.contains("/Sessions/s2/Playing") })
        assertEquals("$jfBase/Sessions/s1/Playing/Stop", requests.last())

        stopGate.complete(Unit)
        advanceUntilIdle()
        assertEquals("$jfBase/Sessions/s2/Playing?playCommand=PlayNow&itemIds=i2&startPositionTicks=0&mediaSourceId=version-i2", requests.last())
    }

    @Test
    fun jellyfinSessionPlayDoesNotSendOldAccountAfterHeldStop() = runTest(dispatcher.scheduler) {
        val jfBase = "http://jf:8096"
        val oldToken = "old-token"
        val replacementToken = "replacement-token"
        val settings = jellyfinSettings(jfBase, oldToken, "u1")
        val requests = mutableListOf<Pair<String, String?>>()
        val stopGate = CompletableDeferred<Unit>()
        val stopStarted = CompletableDeferred<Unit>()
        val client = JellyfinClient(HttpClient(MockEngine) {
            engine {
                dispatcher = this@PlayerControllerTest.dispatcher
                addHandler { request ->
                    val url = request.url.toString()
                    requests += url to request.headers["X-Emby-Token"]
                    if (url.endsWith("/Sessions/session-1/Playing/Stop")) {
                        stopStarted.complete(Unit)
                        stopGate.await()
                    }
                    respond("", HttpStatusCode.NoContent)
                }
            }
        })
        val c = controller(settings, client)
        val target = PlaybackDestination.Receiver(
            CastTarget.JellyfinSessionTarget(JellyfinSession("session-1", "TV", "Jellyfin Web", jfBase)),
        )

        c.loadRequest(jellyfinItemRequest(jfBase, oldToken, "u1", "item-1"), target)
        advanceUntilIdle()
        assertTrue(c.uiState.value.remotePlayback)

        c.loadRequest(jellyfinItemRequest(jfBase, oldToken, "u1", "item-2"), target)
        advanceUntilIdle()
        assertTrue(stopStarted.isCompleted)
        settings.setJellyfinToken(replacementToken)
        stopGate.complete(Unit)
        advanceUntilIdle()

        assertTrue(requests.any { (url, token) ->
            url.endsWith("/Sessions/session-1/Playing/Stop") && token == oldToken
        })
        assertFalse(requests.any { (url, _) ->
            url.contains("/Sessions/session-1/Playing?") && url.contains("itemIds=item-2")
        })
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertFalse(c.uiState.value.remotePlayback)
        assertEquals(replacementToken, settings.jellyfinToken())
    }

    @Test
    fun jellyfinSessionPlayStopsOldAccountAfterHeldPlayResponse() = runTest(dispatcher.scheduler) {
        val jfBase = "http://jf:8096"
        val oldToken = "old-token"
        val replacementToken = "replacement-token"
        val settings = jellyfinSettings(jfBase, oldToken, "u1")
        val requests = mutableListOf<Pair<String, String?>>()
        val playGate = CompletableDeferred<Unit>()
        val playStarted = CompletableDeferred<Unit>()
        val client = JellyfinClient(HttpClient(MockEngine) {
            engine {
                dispatcher = this@PlayerControllerTest.dispatcher
                addHandler { request ->
                    val url = request.url.toString()
                    requests += url to request.headers["X-Emby-Token"]
                    if (url.contains("/Sessions/session-1/Playing?")) {
                        playStarted.complete(Unit)
                        playGate.await()
                    }
                    respond("", HttpStatusCode.NoContent)
                }
            }
        })
        val c = controller(settings, client)
        val target = PlaybackDestination.Receiver(
            CastTarget.JellyfinSessionTarget(JellyfinSession("session-1", "TV", "Jellyfin Web", jfBase)),
        )

        c.loadRequest(jellyfinItemRequest(jfBase, oldToken, "u1", "item-1"), target)
        advanceUntilIdle()
        assertTrue(playStarted.isCompleted)
        settings.setJellyfinToken(replacementToken)
        playGate.complete(Unit)
        advanceUntilIdle()

        assertTrue(requests.any { (url, token) ->
            url.contains("/Sessions/session-1/Playing?") && url.contains("itemIds=item-1") && token == oldToken
        })
        assertTrue(requests.any { (url, token) ->
            url.endsWith("/Sessions/session-1/Playing/Stop") && token == oldToken
        })
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertFalse(c.uiState.value.remotePlayback)
        assertEquals(replacementToken, settings.jellyfinToken())
    }
    @Test
    fun cancelledJellyfinSessionPlayDoesNotBecomePlaybackFailure() = runTest(dispatcher.scheduler) {
        val jfBase = "http://jf:8096"
        val engineDispatcher = dispatcher
        val client = JellyfinClient(HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { throw CancellationException("cancelled") }
            }
        })
        val c = controller(jellyfinSettings(jfBase, "tok", "u1"), client)
        val sourceId = "version-1"
        val jellyfinRequest = request.copy(
            sourceUrl = "$jfBase/Videos/item1/stream?Static=true&MediaSourceId=$sourceId&api_key=tok",
            jellyfinContext = JellyfinPlaybackContext(jfBase, "tok", "u1", "item1", sourceId),
        )
        val target = PlaybackDestination.Receiver(
            CastTarget.JellyfinSessionTarget(JellyfinSession("session-1", "TV", "Jellyfin Web", jfBase)),
        )

        c.loadRequest(jellyfinRequest, target)
        advanceUntilIdle()

        assertNull(c.uiState.value.error)
        assertEquals(PlayerPhase.IDLE, c.uiState.value.phase)
    }


    @Test
    fun unauthorizedJellyfinSessionPlayExpiresCurrentAccount() = runTest(dispatcher.scheduler) {
        val jfBase = "http://jf:8096"
        val token = "expired-token"
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        settings.setJellyfinServer(jfBase)
        settings.setJellyfinToken(token)
        settings.setJellyfinUserId("u1")
        val engineDispatcher = dispatcher
        val client = JellyfinClient(HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { respond("", HttpStatusCode.Unauthorized) }
            }
        })
        val c = controller(settings, client)
        val sourceId = "version-1"
        val jellyfinRequest = request.copy(
            sourceUrl = "$jfBase/Videos/item1/stream?Static=true&MediaSourceId=$sourceId&api_key=$token",
            jellyfinContext = JellyfinPlaybackContext(jfBase, token, "u1", "item1", sourceId),
        )
        val target = PlaybackDestination.Receiver(
            CastTarget.JellyfinSessionTarget(JellyfinSession("session-1", "TV", "Jellyfin Web", jfBase)),
        )

        c.loadRequest(jellyfinRequest, target)
        advanceUntilIdle()

        assertEquals("", settings.jellyfinToken(), "state=" + c.uiState.value)
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals("Jellyfin session expired. Sign in again.", c.uiState.value.error)
    }
    @Test
    fun unauthorizedJellyfinSessionPlayPreservesDestinationWhenTokenClearFails() = runTest(dispatcher.scheduler) {
        for (throwOnFailure in listOf(false, true)) {
            val jfBase = "http://jf:8096"
            val token = "expired-protected-token"
            var canClear = false
            val tokenStore = object : JellyfinTokenStore {
                private var stored: String? = token
                override val persistsAcrossInstances = true
                override fun read(): String? = stored
                override fun write(value: String): Boolean { stored = value; return true }
                override fun clear(): Boolean {
                    if (!canClear) {
                        if (throwOnFailure) throw IllegalStateException("secure deletion failed")
                        return false
                    }
                    stored = null
                    return true
                }
            }
            val settings = SettingsStore(MapSettings(mutableMapOf()), tokenStore)
            settings.setJellyfinServer(jfBase)
            settings.setJellyfinUserId("u1")
            val output = OutputSelection()
            val target = CastTarget.JellyfinSessionTarget(JellyfinSession("session-1", "TV", "Jellyfin Web", jfBase))
            output.selectReceiver(target)
            val engineDispatcher = dispatcher
            val http = HttpClient(MockEngine) {
                engine {
                    dispatcher = engineDispatcher
                    addHandler { respond("", HttpStatusCode.Unauthorized) }
                }
            }
            try {
                val c = PlayerController(settings, outputSelection = output, jellyfin = JellyfinClient(http))
                val sourceId = "version-1"
                val jellyfinRequest = request.copy(
                    sourceUrl = "$jfBase/Videos/item1/stream?Static=true&MediaSourceId=$sourceId&api_key=$token",
                    jellyfinContext = JellyfinPlaybackContext(jfBase, token, "u1", "item1", sourceId),
                )
                c.loadRequest(jellyfinRequest)
                advanceUntilIdle()
                assertEquals(token, settings.jellyfinToken())
                assertEquals(PlaybackDestination.Receiver(target), output.snapshot().destination)
                assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
                assertFalse(c.uiState.value.remotePlayback)
                assertFalse(c.uiState.value.castActive)
                val clearFailure = assertNotNull(c.uiState.value.error)
                assertFalse(token in clearFailure)

                canClear = true
                c.loadRequest(jellyfinRequest)
                advanceUntilIdle()
                assertEquals("", settings.jellyfinToken())
                assertEquals(PlaybackDestination.Local, output.snapshot().destination)
                assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
                assertTrue(assertNotNull(c.uiState.value.error) != clearFailure)
            } finally {
                http.close()
            }
        }
    }

    @Test
    fun forbiddenJellyfinSessionPlayKeepsAccountAndShowsPermissionError() = runTest(dispatcher.scheduler) {
        val jfBase = "http://jf:8096"
        val token = "test-token"
        val settings = SettingsStore(MapSettings(mutableMapOf()))
        settings.setJellyfinServer(jfBase)
        settings.setJellyfinToken(token)
        settings.setJellyfinUserId("u1")
        val engineDispatcher = dispatcher
        val client = JellyfinClient(HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { respond("", HttpStatusCode.Forbidden) }
            }
        })
        val c = controller(settings, client)
        val sourceId = "version-1"
        val jellyfinRequest = request.copy(
            sourceUrl = "$jfBase/Videos/item1/stream?Static=true&MediaSourceId=$sourceId&api_key=$token",
            jellyfinContext = JellyfinPlaybackContext(jfBase, token, "u1", "item1", sourceId),
        )
        val target = PlaybackDestination.Receiver(
            CastTarget.JellyfinSessionTarget(JellyfinSession("session-1", "TV", "Jellyfin Web", jfBase)),
        )

        c.loadRequest(jellyfinRequest, target)
        advanceUntilIdle()

        assertEquals(token, settings.jellyfinToken())
        assertEquals("You do not have permission to start this item on TV", c.uiState.value.error)
    }
    @Test
    fun typedJellyfinItemNegotiatesHlsBeforeProbeAndStopsItsEncoding() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096/proxy"
        val token = "secret-token"
        val sourceId = "server-selected-version"
        val playSessionId = "server-play-session"
        val settings = jellyfinSettings(base, token, "u1")
        val requests = mutableListOf<String>()
        val subtitles = """[{"Type":"Subtitle","IsExternal":true,"Index":2,"Language":"eng","DisplayTitle":"English"}]"""
        val client = jellyfinPlaybackClient(
            sessionId = playSessionId,
            sourceId = sourceId,
            mediaStreams = subtitles,
            requests = requests,
        )
        probeResult = ProbeResult("m3u8", "h264", listOf("aac"), emptyList(), 60_000, isLive = false, pixFmt = "yuv420p")
        val c = controller(settings, client)

        assertTrue(c.loadJellyfinItem("Negotiated title", emptyList(), base, token, "u1", "item1", null))
        assertEquals(JellyfinApi.itemDetailsUrl(base, "u1", "item1"), c.uiState.value.sourceUrl)
        assertTrue(probeUrls.isEmpty())
        advanceUntilIdle()

        val negotiatedUrl = probeUrls.single()
        assertTrue(negotiatedUrl.contains("/Videos/item1/master.m3u8"), negotiatedUrl)
        assertTrue(negotiatedUrl.contains("PlaySessionId=$playSessionId"), negotiatedUrl)
        assertTrue(negotiatedUrl.contains("MediaSourceId=$sourceId"), negotiatedUrl)
        assertTrue(negotiatedUrl.contains("api_key=$token"), negotiatedUrl)
        assertEquals(negotiatedUrl, c.uiState.value.sourceUrl)
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals("English", c.uiState.value.subtitleTracks.single().title)
        assertEquals(c.uiState.value.subtitleTracks.single().url, c.uiState.value.selectedExternalSubtitleUrl)

        c.stopPlayback()
        advanceUntilIdle()
        assertTrue(requests.any { it.startsWith("DELETE ") && it.contains("PlaySessionId=$playSessionId") }, requests.toString())
    }

    @Test
    fun compatibleDestinationMigrationReusesNegotiationAndJellyfinHandoffStopsItFirst() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        lanBase = "http://192.168.1.50:8090"
        val token = "secret-token"
        val sourceId = "selected-version"
        val settings = jellyfinSettings(base, token, "u1")
        val requests = mutableListOf<String>()
        val c = controller(settings, jellyfinPlaybackClient("migration-play-session", sourceId, requests = requests))
        c.loadRequest(jellyfinItemRequest(base, token, "u1", "item1"), PlaybackDestination.Local)
        advanceUntilIdle()
        val negotiatedUrl = c.uiState.value.sourceUrl
        probeResult = null
        probeError = "The owned delivery's cached probe should be reused"

        c.selectAirPlay("airplay-1", "Living Room", 0)
        advanceUntilIdle()
        assertEquals(1, probeUrls.size)
        assertEquals(negotiatedUrl, probeUrls.single())
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
        assertEquals(1, requests.count { it.contains("/PlaybackInfo") })
        assertTrue(requests.none { it.contains("/Videos/ActiveEncodings") })

        val remote = CastTarget.JellyfinSessionTarget(JellyfinSession("remote-session", "TV", "Jellyfin Web", base))
        c.selectReceiver(remote, 0)
        advanceUntilIdle()

        val encodingStop = requests.indexOfFirst { it.startsWith("DELETE ") && it.contains("/Videos/ActiveEncodings") }
        val remotePlay = requests.indexOfFirst { it.contains("/Sessions/remote-session/Playing?") }
        assertTrue(encodingStop >= 0 && remotePlay > encodingStop, requests.toString())
        assertTrue(requests[remotePlay].contains("mediaSourceId=$sourceId"), requests[remotePlay])
        assertEquals(1, requests.count { it.contains("/PlaybackInfo") })
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertTrue(c.uiState.value.remotePlayback)
        c.stopPlayback()
        advanceUntilIdle()
    }

    @Test
    fun freshDeliveryAfterRemoteHandoffIsProbedInsteadOfUsingOldMetadata() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "secret-token"
        val requests = mutableListOf<String>()
        val c = controller(
            jellyfinSettings(base, token, "u1"),
            jellyfinPlaybackClientForFreshDeliveries(requests),
        )
        c.loadRequest(jellyfinItemRequest(base, token, "u1", "item1"), PlaybackDestination.Local)
        advanceUntilIdle()
        val firstDeliveryUrl = probeUrls.single()
        assertTrue(firstDeliveryUrl.contains("PlaySessionId=delivery-1"), firstDeliveryUrl)

        c.selectReceiver(
            CastTarget.JellyfinSessionTarget(JellyfinSession("remote-session", "TV", "Jellyfin Web", base)),
            positionMs = 0,
        )
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertTrue(c.uiState.value.remotePlayback)
        assertTrue(requests.any { it.contains("/Sessions/remote-session/Playing") }, requests.toString())

        probeResult = null
        probeError = "Fresh delivery probe failed"
        c.selectLocal(positionMs = 0)
        advanceUntilIdle()

        assertEquals(2, requests.count { it.contains("/PlaybackInfo") }, requests.toString())
        assertEquals(2, probeUrls.size)
        assertTrue(probeUrls[1] != firstDeliveryUrl, "The new delivery must have its own stream URL: $probeUrls")
        assertTrue(probeUrls[1].contains("PlaySessionId=delivery-2"), probeUrls[1])
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertTrue(
            requests.any { it.startsWith("DELETE ") && it.contains("PlaySessionId=delivery-1") },
            requests.toString(),
        )
        assertTrue(
            requests.any { it.startsWith("DELETE ") && it.contains("PlaySessionId=delivery-2") },
            requests.toString(),
        )
    }

    @Test
    fun stoppedDeliveryIsNegotiatedAndProbedAgainOnReload() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "secret-token"
        val requests = mutableListOf<String>()
        val c = controller(
            jellyfinSettings(base, token, "u1"),
            jellyfinPlaybackClientForFreshDeliveries(requests),
        )
        c.loadRequest(jellyfinItemRequest(base, token, "u1", "item1"), PlaybackDestination.Local)
        advanceUntilIdle()
        val firstDeliveryUrl = probeUrls.single()
        assertTrue(firstDeliveryUrl.contains("PlaySessionId=delivery-1"), firstDeliveryUrl)

        c.stopPlayback()
        advanceUntilIdle()
        assertEquals(PlayerPhase.IDLE, c.uiState.value.phase)
        assertTrue(
            requests.any { it.startsWith("DELETE ") && it.contains("PlaySessionId=delivery-1") },
            requests.toString(),
        )

        probeResult = null
        probeError = "Fresh delivery probe failed"
        c.loadJellyfinItem("Fixture", emptyList(), base, token, "u1", "item1", null)
        advanceUntilIdle()

        assertEquals(2, requests.count { it.contains("/PlaybackInfo") }, requests.toString())
        assertEquals(2, probeUrls.size)
        assertTrue(probeUrls[1] != firstDeliveryUrl, "The new delivery must have its own stream URL: $probeUrls")
        assertTrue(probeUrls[1].contains("PlaySessionId=delivery-2"), probeUrls[1])
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertTrue(
            requests.any { it.startsWith("DELETE ") && it.contains("PlaySessionId=delivery-2") },
            requests.toString(),
        )
    }

    @Test
    fun changedAccountDoesNotCommitLateNegotiationAndDisposesItsSession() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "old-token"
        val settings = jellyfinSettings(base, token, "u1")
        val gate = CompletableDeferred<Unit>()
        val requests = mutableListOf<String>()
        val c = controller(settings, jellyfinPlaybackClient("late-session", "server-version", requests = requests, playbackGate = gate))
        c.loadJellyfinItem("Fixture", emptyList(), base, token, "u1", "item1", null)
        advanceUntilIdle()
        assertTrue(probeUrls.isEmpty())

        settings.setJellyfinToken("new-token")
        gate.complete(Unit)
        advanceUntilIdle()

        assertEquals("new-token", settings.jellyfinToken())
        assertEquals(JellyfinApi.itemDetailsUrl(base, "u1", "item1"), c.uiState.value.sourceUrl)
        assertTrue(probeUrls.isEmpty())
        assertTrue(requests.any { it.startsWith("DELETE ") && it.contains("PlaySessionId=late-session") }, requests.toString())
    }

    @Test
    fun stoppingDuringNegotiatedProbeDisposesEncodingAndIgnoresLateProbe() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "secret-token"
        val settings = jellyfinSettings(base, token, "u1")
        val requests = mutableListOf<String>()
        val c = controller(settings, jellyfinPlaybackClient("probe-session", "version-1", requests = requests))
        deferProbe = true
        c.loadJellyfinItem("Fixture", emptyList(), base, token, "u1", "item1", null)
        advanceUntilIdle()
        val lateProbe = assertNotNull(pendingProbe)

        c.stopPlayback()
        advanceUntilIdle()
        assertEquals(PlayerUiState(), c.uiState.value)
        assertTrue(requests.any { it.startsWith("DELETE ") && it.contains("PlaySessionId=probe-session") }, requests.toString())

        lateProbe(probeResult, probeError)
        advanceUntilIdle()
        assertEquals(PlayerUiState(), c.uiState.value)
    }

    @Test
    fun jellyfinPlaybackApi401ExpiresOnlyMatchingAccountBeforeAnyProbe() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "expired-token"
        val settings = jellyfinSettings(base, token, "u1")
        val c = controller(settings, jellyfinPlaybackClient(playbackStatus = HttpStatusCode.Unauthorized))

        c.loadJellyfinItem("Fixture", emptyList(), base, token, "u1", "item1", null)
        advanceUntilIdle()

        assertEquals("", settings.jellyfinToken())
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals("Jellyfin session expired. Sign in again.", c.uiState.value.error)
        assertTrue(probeUrls.isEmpty())
    }

    @Test
    fun accountReplacementWhileNativeProbeIsSuspendedStopsOnlyOldDelivery() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "old-token"
        val settings = jellyfinSettings(base, token, "u1")
        val requests = mutableListOf<String>()
        val c = controller(settings, jellyfinPlaybackClient("probe-session", "server-version", requests = requests))
        deferProbe = true

        c.loadJellyfinItem("Fixture", emptyList(), base, token, "u1", "item1", null)
        advanceUntilIdle()
        val suspendedProbe = assertNotNull(pendingProbe)

        settings.setJellyfinToken("replacement-token")
        suspendedProbe(probeResult, probeError)
        advanceUntilIdle()

        assertEquals("replacement-token", settings.jellyfinToken())
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals(1, requests.count { it.contains("/PlaybackInfo") }, requests.toString())
        assertEquals(
            1,
            requests.count { it.startsWith("DELETE ") && it.contains("/Videos/ActiveEncodings") },
            requests.toString(),
        )
        assertTrue(
            requests.any {
                it.startsWith("DELETE ") &&
                    it.contains("/Videos/ActiveEncodings") &&
                    it.contains("PlaySessionId=probe-session")
            },
            requests.toString(),
        )
    }

    @Test
    fun accountReplacementWhileReceiverCapabilitiesAreSuspendedStopsOldDeliveryBeforeRouting() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "old-token"
        val userId = "u1"
        val replacementBase = "http://replacement-jf:8096"
        val replacementToken = "replacement-token"
        val replacementUserId = "u2"
        val settings = jellyfinSettings(base, token, userId)
        val requests = mutableListOf<String>()
        val profileRequested = CompletableDeferred<Unit>()
        val profileGate = CompletableDeferred<Unit>()
        val resolver = object : OutputCapabilityResolver {
            override suspend fun profileFor(target: CastTarget): OutputMediaProfile {
                profileRequested.complete(Unit)
                profileGate.await()
                return OutputMediaProfiles.familyDefault(target)
            }

            override fun invalidate(target: CastTarget) = Unit
        }
        val castRequests = mutableListOf<String>()
        val engineDispatcher = dispatcher
        val castClient = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    castRequests += request.headers["SOAPACTION"] ?: request.url.toString()
                    respond("<ok/>", HttpStatusCode.OK)
                }
            }
        }
        val target = CastTarget.Dlna(
            DlnaDevice("usn-account-change", "http://192.168.1.9/desc.xml", "Living Room", "http://192.168.1.9/control"),
        )
        val c = controller(
            settings,
            jellyfinPlaybackClient("capability-session", "version-1", requests = requests),
            capabilityResolver = resolver,
        )
        CastDispatcher.install(c, castClient)
        try {
            c.loadRequest(
                jellyfinItemRequest(base, token, userId, "item1", mediaSourceId = "version-1"),
                PlaybackDestination.Receiver(target),
            )
            advanceUntilIdle()
            assertTrue(profileRequested.isCompleted)
            assertEquals(1, requests.count { it.contains("/PlaybackInfo") }, requests.toString())
            assertEquals(1, probeUrls.size, probeUrls.toString())
            assertTrue(
                probeUrls.single().contains(
                    "/Videos/item1/master.m3u8?PlaySessionId=capability-session&MediaSourceId=version-1",
                ),
                probeUrls.single(),
            )

            settings.setJellyfinServer(replacementBase)
            settings.setJellyfinToken(replacementToken)
            settings.setJellyfinUserId(replacementUserId)
            profileGate.complete(Unit)
            advanceUntilIdle()

            assertEquals(replacementBase, settings.jellyfinServer())
            assertEquals(replacementToken, settings.jellyfinToken())
            assertEquals(replacementUserId, settings.jellyfinUserId())
            assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
            assertNull(c.uiState.value.route)
            assertNull(c.uiState.value.proxyUrl)
            assertFalse(c.uiState.value.remotePlayback)
            assertFalse(c.uiState.value.castActive)
            assertTrue(hlsModes.isEmpty(), "HLS sessions started: $hlsModes")
            assertTrue(castRequests.isEmpty(), "Old library media was dispatched: $castRequests")
            assertEquals(1, requests.count { it.contains("/PlaybackInfo") }, requests.toString())
            assertEquals(
                listOf("DELETE $base/Videos/ActiveEncodings?DeviceId=rigel-ios&PlaySessionId=capability-session"),
                requests.filter { it.startsWith("DELETE ") && it.contains("/Videos/ActiveEncodings") },
                requests.toString(),
            )
        } finally {
            profileGate.complete(Unit)
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }

    @Test
    fun nativeJellyfinStream401DoesNotExpireAccount() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "valid-token"
        val settings = jellyfinSettings(base, token, "u1")
        val c = controller(settings, jellyfinPlaybackClient("native-stream-session", "version-1"))
        c.loadJellyfinItem("Fixture", emptyList(), base, token, "u1", "item1", null)
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        c.reportError("HTTP 401 Unauthorized")
        advanceUntilIdle()

        assertEquals(token, settings.jellyfinToken())
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        c.stopPlayback()
        advanceUntilIdle()
    }

    @Test
    fun missingJellyfinClientFailsWithoutProbingItemIdentity() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "valid-token"
        val c = controller(jellyfinSettings(base, token, "u1"))

        c.loadJellyfinItem("Fixture", emptyList(), base, token, "u1", "item1", null)
        advanceUntilIdle()

        assertEquals("Jellyfin client is not configured", c.uiState.value.error)
        assertTrue(probeUrls.isEmpty())
        assertEquals(JellyfinApi.itemDetailsUrl(base, "u1", "item1"), c.uiState.value.sourceUrl)
    }

    @Test
    fun failedNegotiatedProbeStopsEncodingWithoutClearingCredentials() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "valid-token"
        val settings = jellyfinSettings(base, token, "u1")
        val requests = mutableListOf<String>()
        val c = controller(settings, jellyfinPlaybackClient("failed-probe-session", "version-1", requests = requests))
        probeResult = null
        probeError = "HTTP 401 Unauthorized"

        c.loadJellyfinItem("Fixture", emptyList(), base, token, "u1", "item1", null)
        advanceUntilIdle()

        assertEquals(token, settings.jellyfinToken())
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertTrue(requests.any { it.startsWith("DELETE ") && it.contains("PlaySessionId=failed-probe-session") }, requests.toString())
    }

    @Test
    fun negotiatedProxyStartupFailureReleasesProxyAndJellyfinSessions() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "valid-token"
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY"))).also {
            it.setJellyfinServer(base)
            it.setJellyfinToken(token)
            it.setJellyfinUserId("u1")
        }
        val requests = mutableListOf<String>()
        val c = controller(settings, jellyfinPlaybackClient("proxy-session", "version-1", requests = requests))
        serverPort = -1
        serverError = "proxy listener failed"

        c.loadJellyfinItem("Fixture", emptyList(), base, token, "u1", "item1", null)
        advanceUntilIdle()

        assertEquals(1, requests.count { it.contains("/PlaybackInfo") }, requests.toString())
        assertEquals(1, probeUrls.size)
        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals("proxy listener failed", c.uiState.value.error)
        assertTrue(serverStopped, "The failed local proxy listener must be stopped")
        assertEquals(1, hlsSessionIds.size)
        assertTrue(stoppedSessions.contains(hlsSessionIds.single()), stoppedSessions.toString())
        assertTrue(
            requests.any { it.startsWith("DELETE ") && it.contains("PlaySessionId=proxy-session") },
            requests.toString(),
        )
        assertEquals(token, settings.jellyfinToken())
    }

    @Test
    fun negotiatedEncodingStaysOwnedDuringFallbackAndStopsAfterTerminalFailure() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "valid-token"
        val settings = jellyfinSettings(base, token, "u1")
        val requests = mutableListOf<String>()
        val c = controller(settings, jellyfinPlaybackClient("fallback-session", "version-1", requests = requests))
        c.loadJellyfinItem("Fixture", emptyList(), base, token, "u1", "item1", null)
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        c.reportError("native decoder failed")
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.TRANSCODE, c.uiState.value.route)
        assertTrue(
            requests.none { it.startsWith("DELETE ") && it.contains("PlaySessionId=fallback-session") },
            requests.toString(),
        )

        c.reportError("fallback decoder failed")
        advanceUntilIdle()

        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertEquals("fallback decoder failed", c.uiState.value.error)
        assertEquals(
            1,
            requests.count { it.startsWith("DELETE ") && it.contains("PlaySessionId=fallback-session") },
            requests.toString(),
        )
        assertEquals(token, settings.jellyfinToken())
    }

    @Test
    fun replacementNegotiationWaitsForPreviousEncodingStop() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "secret-token"
        val settings = jellyfinSettings(base, token, "u1")
        val requests = mutableListOf<String>()
        val stopGate = CompletableDeferred<Unit>()
        var sessionNumber = 0
        val engineDispatcher = dispatcher
        val client = JellyfinClient(HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    val url = request.url.toString()
                    requests += "${request.method.value} $url"
                    when {
                        url.contains("/PlaybackInfo") -> {
                            sessionNumber += 1
                            respond(jellyfinPlaybackResponse("replacement-$sessionNumber", "source-$sessionNumber"), HttpStatusCode.OK)
                        }
                        url.contains("/Videos/ActiveEncodings") -> {
                            stopGate.await()
                            respond("", HttpStatusCode.NoContent)
                        }
                        else -> respond("", HttpStatusCode.NoContent)
                    }
                }
            }
        })
        val c = controller(settings, client)
        c.loadRequest(jellyfinItemRequest(base, token, "u1", "item1"), PlaybackDestination.Local)
        advanceUntilIdle()

        c.loadRequest(jellyfinItemRequest(base, token, "u1", "item2"), PlaybackDestination.Local)
        advanceUntilIdle()
        assertTrue(requests.any { it.contains("/Videos/ActiveEncodings") })
        assertTrue(requests.none { it.contains("/Items/item2/PlaybackInfo") }, requests.toString())

        stopGate.complete(Unit)
        advanceUntilIdle()
        val stopIndex = requests.indexOfFirst { it.contains("/Videos/ActiveEncodings") }
        val replacementIndex = requests.indexOfFirst { it.contains("/Items/item2/PlaybackInfo") }
        assertTrue(replacementIndex > stopIndex, requests.toString())
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        c.stopPlayback()
        advanceUntilIdle()
    }

    @Test
    fun selectingJellyfinReceiverAfterStopDoesNotReuseStoppedItem() = runTest(dispatcher.scheduler) {
        val jfBase = "http://jf:8096"
        val token = "secret-token"
        val requests = mutableListOf<String>()
        val client = jellyfinPlaybackClient(sessionId = "local-play-session", sourceId = "version-1", requests = requests)
        val c = controller(jellyfinSettings(jfBase, token, "u1"), client)
        c.loadRequest(jellyfinItemRequest(jfBase, token, "u1", "item1", "version-1"), PlaybackDestination.Local)
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)

        c.stopPlayback()
        advanceUntilIdle()
        assertEquals(PlayerPhase.IDLE, c.uiState.value.phase)
        assertTrue(requests.any { it.contains("/Videos/ActiveEncodings") && it.contains("PlaySessionId=local-play-session") })

        val target = CastTarget.JellyfinSessionTarget(JellyfinSession("session-1", "TV", "Jellyfin Web", jfBase))
        c.selectReceiver(target, positionMs = 0)
        advanceUntilIdle()

        assertTrue(requests.none { it.contains("/Sessions/session-1/Playing") }, "stopped Jellyfin media must not be resent: $requests")
        assertEquals(PlayerPhase.IDLE, c.uiState.value.phase)
    }
    @Test
    fun stopPlaybackRetainsStopBeforeReplacementPlay() = runTest(dispatcher.scheduler) {
        val jfBase = "http://jf:8096"
        val requests = mutableListOf<String>()
        val firstStopGate = CompletableDeferred<Unit>()
        var stopCount = 0
        val engineDispatcher = dispatcher
        val client = JellyfinClient(HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    val url = request.url.toString()
                    requests += url
                    if (url.endsWith("/Playing/Stop")) {
                        stopCount += 1
                        if (stopCount == 1) firstStopGate.await()
                    }
                    respond("", HttpStatusCode.NoContent)
                }
            }
        })
        val c = controller(jellyfinSettings(jfBase, "tok", "u1"), client)
        fun jfRequest(itemId: String): IntakeRequest {
            val sourceId = "version-$itemId"
            return request.copy(
                sourceUrl = "$jfBase/Videos/$itemId/stream?Static=true&MediaSourceId=$sourceId&api_key=tok",
                jellyfinContext = JellyfinPlaybackContext(jfBase, "tok", "u1", itemId, sourceId),
            )
        }
        fun jfTarget(sessionId: String) = PlaybackDestination.Receiver(
            CastTarget.JellyfinSessionTarget(JellyfinSession(sessionId, "TV", "Jellyfin Web", jfBase)),
        )

        c.loadRequest(jfRequest("i1"), jfTarget("s1"))
        advanceUntilIdle()
        c.stopPlayback()
        advanceUntilIdle()

        c.loadRequest(jfRequest("i2"), jfTarget("s2"))
        advanceUntilIdle()
        assertTrue(requests.none { it.contains("/Sessions/s2/Playing") })

        firstStopGate.complete(Unit)
        advanceUntilIdle()
        assertEquals("$jfBase/Sessions/s2/Playing?playCommand=PlayNow&itemIds=i2&startPositionTicks=0&mediaSourceId=version-i2", requests.last())
    }

    @Test
    fun directAudioMp4UsesAudioMimeForRoku() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult("mp4", null, listOf("aac"), emptyList(), 60_000, isLive = false, pixFmt = null)
        val posted = mutableListOf<String>()
        val engineDispatcher = dispatcher
        val client = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    val url = request.url.toString()
                    if (url.endsWith("/query/apps")) {
                        respond("<apps><app id=\"15985\">Play on Roku</app></apps>", HttpStatusCode.OK)
                    } else {
                        posted += url
                        respond("", HttpStatusCode.OK)
                    }
                }
            }
        }
        val c = controller()
        val target = CastTarget.Roku(RokuDevice("r-aac", "http://192.168.1.9:8060/", "Roku"))
        CastDispatcher.install(c, client)
        try {
            c.loadRequest(
                request.copy(sourceUrl = "http://192.168.1.20/audio.mp4"),
                PlaybackDestination.Receiver(target),
            )
            advanceUntilIdle()
            assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
            assertTrue(posted.single().contains("t=a"))
            assertTrue(posted.single().contains("songformat=aac"))
        } finally {
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }

    @Test
    fun receiverSelectionWithExternalSubtitleCastsOriginalSourceDirectly() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        val source = "http://192.168.1.20/movie.mp4"
        val posted = mutableListOf<String>()
        val engineDispatcher = dispatcher
        val client = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    val url = request.url.toString()
                    if (url.endsWith("/query/apps")) {
                        respond("""<apps><app id="15985">Play on Roku</app></apps>""", HttpStatusCode.OK)
                    } else {
                        posted += url
                        respond("", HttpStatusCode.OK)
                    }
                }
            }
        }
        val c = controller()
        val target = CastTarget.Roku(RokuDevice("subtitle-r1", "http://192.168.1.9:8060/", "Roku"))
        val track = SubtitleTrack("https://subtitles.example/movie.srt", "en", "English")
        CastDispatcher.install(c, client)
        try {
            c.loadRequest(
                request.copy(sourceUrl = source, subtitleTracks = listOf(track)),
                PlaybackDestination.Receiver(target),
            )
            advanceUntilIdle()

            assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
            assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
            assertTrue(c.uiState.value.remotePlayback)
            assertTrue(hlsSessionIds.isEmpty())
            assertTrue(posted.any { it.contains("movie.mp4") }, "posted=$posted")
        } finally {
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }

    @Test
    fun jellyfinTokenIsNeverSentToGenericReceivers() = runTest(dispatcher.scheduler) {
        lanBase = "http://192.168.1.50:8090"
        probeResult = ProbeResult("mp4", "h264", listOf("aac"), emptyList(), 60_000, isLive = false, pixFmt = "yuv420p", width = 1280, height = 720, videoLevel = 40, frameRate = 24.0)
        val posted = mutableListOf<String>()
        val engineDispatcher = dispatcher
        val client = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { castRequest ->
                    val url = castRequest.url.toString()
                    if (url.endsWith("/query/apps")) {
                        respond("""<apps><app id="15985">Play on Roku</app></apps>""", HttpStatusCode.OK)
                    } else {
                        posted += url
                        respond("", HttpStatusCode.OK)
                    }
                }
            }
        }
        val base = "http://192.168.1.20:8096"
        val token = "secret-token"
        val settings = jellyfinSettings(base, token, "user1")
        val jellyfinClient = jellyfinPlaybackClient(sessionId = "cast-play-session", sourceId = "high")
        val c = controller(settings, jellyfinClient)
        val target = CastTarget.Roku(RokuDevice("jellyfin-r1", "http://192.168.1.9:8060/", "Roku"))
        val source = "$base/Videos/item1/stream?Static=true&MediaSourceId=high&api_key=$token"
        val requests = listOf(
            jellyfinItemRequest(base, token, "user1", "item1", "high"),
            request.copy(sourceUrl = source),
            request.copy(sourceUrl = source.replace("api_key=", "api%5Fkey=")),
        )
        CastDispatcher.install(c, client)
        try {
            for (playRequest in requests) {
                val postedBefore = posted.size
                c.loadRequest(playRequest, PlaybackDestination.Receiver(target))
                advanceUntilIdle()

                assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
                assertEquals(PlaybackRoute.REMUX, c.uiState.value.route)
                assertEquals("remux", hlsModes.last())
                val castRequests = posted.drop(postedBefore).filter { it.contains("/input/15985") }
                assertTrue(castRequests.any { it.contains("192.168.1.50%3A8090") && it.contains("hls%2Fs1%2Fout.m3u8") }, "posted=$posted")
                assertTrue(castRequests.none { it.contains(token) }, "receiver requests must not include the Jellyfin token: $castRequests")

                c.stopPlayback()
                advanceUntilIdle()
            }
        } finally {
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }
    @Test
    fun jellyfinCredentialsStayOutOfCastUrlAndTitleHelpers() = runTest(dispatcher.scheduler) {
        val base = "http://192.168.1.20:8096"
        val token = "secret-token"
        val c = controller()
        c.loadRequest(
            request.copy(
                sourceUrl = "$base/Videos/item1/stream?Static=true&MediaSourceId=high&api_key=$token",
                title = "Fixture title",
            ),
            PlaybackDestination.Local,
        )
        advanceUntilIdle()

        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
        assertNull(c.remoteCastUrl())
        assertEquals("Fixture title", c.remoteCastTitle())
        assertFalse(c.remoteCastTitle().contains(token))
    }
    @Test
    fun stopPlaybackRetainsReceiverStopBeforeReplacementCast() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        val source = "http://192.168.1.20/movie.mp4"
        val actions = mutableListOf<String>()
        val firstStopGate = CompletableDeferred<Unit>()
        var stopCount = 0
        val engineDispatcher = dispatcher
        val client = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    val action = request.headers["SOAPACTION"] ?: ""
                    actions += action
                    if (action.contains("#Stop")) {
                        stopCount += 1
                        if (stopCount == 1) firstStopGate.await()
                    }
                    respond("<ok/>", HttpStatusCode.OK)
                }
            }
        }
        lanBase = "http://192.168.1.50:8090"
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
        val target = CastTarget.Dlna(
            DlnaDevice("stop-r1", "http://192.168.1.9/desc.xml", "Living Room", "http://192.168.1.9/control"),
        )
        CastDispatcher.install(c, client)
        try {
            c.loadRequest(request.copy(sourceUrl = source), PlaybackDestination.Receiver(target))
            advanceUntilIdle()
            val initialCasts = actions.count { it.contains("#SetAVTransportURI") }
            assertEquals(1, initialCasts, "state=${c.uiState.value} hls=${hlsModes} actions=${actions}")

            c.stopPlayback()
            advanceUntilIdle()
            c.loadRequest(request.copy(sourceUrl = source), PlaybackDestination.Receiver(target))
            advanceUntilIdle()
            assertEquals(initialCasts, actions.count { it.contains("#SetAVTransportURI") })

            firstStopGate.complete(Unit)
            advanceUntilIdle()
            assertEquals(initialCasts + 1, actions.count { it.contains("#SetAVTransportURI") })
        } finally {
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }
    @Test
    fun airPlayDirectFailureFallsBackToRemuxForH264Aac() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult(
            "matroska",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        lanBase = "http://192.168.1.50:8090"
        val c = controller()
        c.loadRequest(
            request.copy(sourceUrl = "http://h/movie.mkv"),
            PlaybackDestination.AirPlay("air-1", "Living Room"),
        )
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
        assertTrue(hlsModes.isEmpty())

        c.reportError("AirPlay decoder failure")
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.REMUX, c.uiState.value.route)
        assertEquals(listOf("remux"), hlsModes)
        assertEquals(listOf("aac"), hlsPassthroughAudioCodecs.single())
    }

    @Test
    fun airPlayDirectFailureFallsBackToTranscodeForUnsupportedVideo() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult(
            "webm",
            "vp9",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        lanBase = "http://192.168.1.50:8090"
        val c = controller()
        c.loadRequest(
            request.copy(sourceUrl = "http://h/movie.webm"),
            PlaybackDestination.AirPlay("air-1", "Living Room"),
        )
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        c.reportError("AirPlay unsupported video")
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.TRANSCODE, c.uiState.value.route)
        assertEquals(listOf("transcode"), hlsModes)
    }

    @Test
    fun switchingLocalDirectH264FlacToAirPlayBuildsLanRemuxWithAacOnlyPolicy() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("flac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        lanBase = "http://192.168.1.50:8090"
        val c = controller()
        c.loadRequest(
            request.copy(sourceUrl = "http://h/movie.mp4"),
            PlaybackDestination.Local,
        )
        advanceUntilIdle()
        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
        assertTrue(hlsModes.isEmpty())

        c.selectAirPlay("air-1", "Living Room", positionMs = 0)
        advanceUntilIdle()

        val state = c.uiState.value
        assertEquals(PlayerPhase.PLAYING, state.phase)
        assertEquals(PlaybackRoute.REMUX, state.route)
        assertEquals("http://192.168.1.50:8090/hls/s1/out.m3u8", state.proxyUrl)
        assertNull(state.error)
        assertEquals(listOf("remux"), hlsModes)
        assertEquals(emptyList(), hlsPassthroughAudioCodecs.single())
    }

    @Test
    fun airPlayAlwaysProxySkipsDirectAttempt() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        lanBase = "http://192.168.1.50:8090"
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
        c.loadRequest(
            request.copy(sourceUrl = "http://h/movie.mp4"),
            PlaybackDestination.AirPlay("air-1", "Living Room"),
        )
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.REMUX, c.uiState.value.route)
        assertEquals(listOf("remux"), hlsModes)
    }

    @Test
    fun localRoutingRemainsConservativeForUnsupportedVideo() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult("webm", "vp9", listOf("opus"), emptyList(), 60_000, isLive = false, pixFmt = "yuv420p")
        val c = controller()
        c.loadRequest(request.copy(sourceUrl = "http://h/movie.webm"), PlaybackDestination.Local)
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.TRANSCODE, c.uiState.value.route)
        assertEquals(listOf("transcode"), hlsModes)

    }
    @Test
    fun airPlayProxyRequiresLanBase() = runTest(dispatcher.scheduler) {
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        val c = controller(settings)
        c.loadRequest(
            request.copy(sourceUrl = "http://h/movie.mp4"),
            PlaybackDestination.AirPlay("air-1", "Living Room"),
        )
        advanceUntilIdle()

        assertEquals(PlayerPhase.ERROR, c.uiState.value.phase)
        assertTrue(c.uiState.value.error!!.contains("No local network address"), "error=${c.uiState.value.error}")
    }

    @Test
    fun airPlaySubtitleSelectionKeepsDirectPlayback() = runTest(dispatcher.scheduler) {
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "DIRECT")))
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        lanBase = "http://192.168.1.50:8090"
        val c = controller(settings)
        c.loadRequest(
            request.copy(sourceUrl = "http://h/movie.mp4"),
            PlaybackDestination.AirPlay("air-1", "Living Room"),
        )
        advanceUntilIdle()
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)

        val track = SubtitleTrack("https://subtitles.example/movie.srt", "en", "English")
        c.selectExternalSubtitle(track, positionMs = 15_000)
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(PlaybackRoute.DIRECT, c.uiState.value.route)
        assertNull(c.uiState.value.proxyUrl)
        assertEquals(track.url, c.uiState.value.selectedExternalSubtitleUrl)
        assertTrue(hlsSessionIds.isEmpty())
    }

    @Test
    fun cancellingPendingRokuCastStopsTheReceiver() = runTest(dispatcher.scheduler) {
        val urls = mutableListOf<String>()
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        val castGate = CompletableDeferred<Unit>()
        val engineDispatcher = dispatcher
        val client = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    val url = request.url.toString()
                    urls += url
                    if (url.contains("/input/15985")) castGate.await()
                    respond("", HttpStatusCode.OK)
                }
            }
        }
        val c = controller()
        val target = CastTarget.Roku(RokuDevice("pending-r1", "http://192.168.1.9:8060/", "Roku"))
        CastDispatcher.install(c, client)
        try {
            c.loadRequest(
                request.copy(sourceUrl = "http://192.168.1.20/movie.mp4"),
                PlaybackDestination.Receiver(target),
            )
            advanceUntilIdle()

            c.stopPlayback()
            advanceUntilIdle()
            castGate.complete(Unit)
            advanceUntilIdle()

            assertTrue(urls.any { it.endsWith("/keypress/Home") }, "urls=$urls")
        } finally {
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }
    @Test
    fun receiverProgressIsQueriedBeforeHandoff() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        val actions = mutableListOf<String>()
        val engineDispatcher = dispatcher
        val client = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    val action = request.headers["SOAPACTION"] ?: ""
                    actions += action
                    if (action.contains("#GetPositionInfo")) {
                        respond(
                            "<RelTime>00:00:12</RelTime><TrackDuration>00:01:00</TrackDuration>",
                            HttpStatusCode.OK,
                        )
                    } else {
                        respond("<ok/>", HttpStatusCode.OK)
                    }
                }
            }
        }
        val c = controller()
        val target = CastTarget.Dlna(
            DlnaDevice("handoff-r1", "http://192.168.1.9/desc.xml", "Living Room", "http://192.168.1.9/control"),
        )
        CastDispatcher.install(c, client)
        try {
            c.loadRequest(
                request.copy(sourceUrl = "http://192.168.1.20/movie.mp4"),
                PlaybackDestination.Receiver(target),
            )
            advanceUntilIdle()
            assertTrue(c.uiState.value.remotePlayback)

            c.selectLocal(positionMs = 0)
            advanceUntilIdle()

            assertEquals(12_000L, c.uiState.value.startPositionMs)
            assertFalse(c.uiState.value.remotePlayback)
            assertNull(CastDispatcher.activeTarget())
            val positionIndex = actions.indexOfFirst { it.contains("#GetPositionInfo") }
            val stopIndex = actions.indexOfFirst { it.contains("#Stop") }
            assertTrue(positionIndex >= 0 && positionIndex < stopIndex, "actions=$actions")
        } finally {
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }

    @Test
    fun proxyReceiverProgressAddsSourceStartOffsetBeforeHandoff() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        lanBase = "http://192.168.1.50:8090"
        val actions = mutableListOf<String>()
        val engineDispatcher = dispatcher
        val client = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    val action = request.headers["SOAPACTION"] ?: ""
                    actions += action
                    if (action.contains("#GetPositionInfo")) {
                        respond(
                            "<RelTime>00:00:03</RelTime><TrackDuration>00:01:00</TrackDuration>",
                            HttpStatusCode.OK,
                        )
                    } else {
                        respond("<ok/>", HttpStatusCode.OK)
                    }
                }
            }
        }
        val settings = SettingsStore(MapSettings(mutableMapOf("route_override" to "ALWAYS_PROXY")))
        val c = controller(settings)
        val target = CastTarget.Dlna(
            DlnaDevice("handoff-proxy-1", "http://192.168.1.9/desc.xml", "Living Room", "http://192.168.1.9/control"),
        )
        CastDispatcher.install(c, client)
        try {
            c.loadRequest(
                request.copy(sourceUrl = "http://192.168.1.20/movie.mp4"),
                PlaybackDestination.Receiver(target),
            )
            advanceUntilIdle()
            c.seek(20_000, 60_000)
            advanceUntilIdle()

            c.selectLocal(positionMs = 0)
            advanceUntilIdle()

            assertEquals(23_000L, c.uiState.value.startPositionMs)
            assertEquals(23_000L, hlsOffsets.last())
            assertTrue(actions.any { it.contains("#GetPositionInfo") })
        } finally {
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }

    @Test
    fun receiverPositionQueryCannotResurrectAfterNewLoad() = runTest(dispatcher.scheduler) {
        probeResult = ProbeResult(
            "mp4",
            "h264",
            listOf("aac"),
            emptyList(),
            60_000,
            isLive = false,
            pixFmt = "yuv420p",
            width = 1280,
            height = 720,
            videoLevel = 40,
            frameRate = 24.0,
        )
        val positionGate = CompletableDeferred<Unit>()
        val engineDispatcher = dispatcher
        val client = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { request ->
                    val action = request.headers["SOAPACTION"] ?: ""
                    if (action.contains("#GetPositionInfo")) {
                        positionGate.await()
                        respond(
                            "<RelTime>00:00:45</RelTime><TrackDuration>00:01:00</TrackDuration>",
                            HttpStatusCode.OK,
                        )
                    } else {
                        respond("<ok/>", HttpStatusCode.OK)
                    }
                }
            }
        }
        val c = controller()
        val target = CastTarget.Dlna(
            DlnaDevice("handoff-race-1", "http://192.168.1.9/desc.xml", "Living Room", "http://192.168.1.9/control"),
        )
        CastDispatcher.install(c, client)
        try {
            c.loadRequest(
                request.copy(sourceUrl = "http://192.168.1.20/old.mp4"),
                PlaybackDestination.Receiver(target),
            )
            advanceUntilIdle()

            c.selectLocal(positionMs = 0)
            advanceUntilIdle()
            c.loadRequest(request.copy(sourceUrl = "http://h/new.mp4"), PlaybackDestination.Local)
            positionGate.complete(Unit)
            advanceUntilIdle()

            assertEquals("http://h/new.mp4", c.uiState.value.sourceUrl)
            assertEquals(PlaybackDestination.Local.kind, c.uiState.value.destinationKind)
            assertEquals(0L, c.uiState.value.startPositionMs)
            assertNull(CastDispatcher.activeTarget())
        } finally {
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }

    @Test
    fun nativePlayheadIsUsedForDirectDecoderFallback() = runTest(dispatcher.scheduler) {
        val c = controller()
        c.loadRequest(request)
        advanceUntilIdle()

        c.reportError("decoder failure", nativePositionMs = 27_500)
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, c.uiState.value.phase)
        assertEquals(27_500L, c.uiState.value.startPositionMs)
        assertEquals(27_500L, hlsOffsets.single())
    }
    @Test
    fun unsupportedReceiverPositionUsesCallerFallback() = runTest(dispatcher.scheduler) {
        val engineDispatcher = dispatcher
        val client = HttpClient(MockEngine) {
            engine {
                dispatcher = engineDispatcher
                addHandler { respond("<ok/>", HttpStatusCode.OK) }
            }
        }
        val c = controller()
        val target = CastTarget.Dlna(
            DlnaDevice("handoff-null-1", "http://192.168.1.9/desc.xml", "Living Room", "http://192.168.1.9/control"),
        )
        CastDispatcher.install(c, client)
        try {
            c.loadRequest(
                request.copy(sourceUrl = "http://192.168.1.20/movie.mp4"),
                PlaybackDestination.Receiver(target),
            )
            advanceUntilIdle()
            c.selectLocal(positionMs = 17_000)
            advanceUntilIdle()

            assertEquals(17_000L, c.uiState.value.startPositionMs)
            assertNull(CastDispatcher.activeTarget())
        } finally {
            CastDispatcher.clearActive()
            CastDispatcher.install(null, null)
        }
    }

    @Test
    fun JellyfinStreamCredentialsAreNotStoredInLinkHistory() = runTest(dispatcher.scheduler) {
        val base = "http://jf:8096"
        val token = "private-token"
        val settings = jellyfinSettings(base, token, "user-1")
        val controller = controller(settings, jellyfinPlaybackClient(sessionId = "history-session", sourceId = "version-2"))

        controller.loadRequest(jellyfinItemRequest(base, token, "user-1", "item1", "version-2"), PlaybackDestination.Local)
        advanceUntilIdle()

        assertEquals(PlayerPhase.PLAYING, controller.uiState.value.phase)
        assertTrue(settings.linkHistory().isEmpty())
        assertFalse(settings.linkHistory().any { token in it.url })
        controller.stopPlayback()
        advanceUntilIdle()
    }
}
