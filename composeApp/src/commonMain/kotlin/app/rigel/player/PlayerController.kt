package app.rigel.player

import app.rigel.bridge.Bridges
import app.rigel.bridge.ProbeResult
import app.rigel.gateway.FormatRouter
import app.rigel.gateway.PlaybackRoute
import app.rigel.intake.IntakeRequest
import app.rigel.intake.UrlIntake
import app.rigel.settings.RouteOverride
import app.rigel.settings.SettingsStore
import co.touchlab.kermit.Logger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.random.Random

enum class PlayerPhase { IDLE, PROBING, PREPARING_PROXY, PLAYING, ERROR }

data class PlayerUiState(
    val phase: PlayerPhase = PlayerPhase.IDLE,
    val sourceUrl: String? = null,
    val filename: String? = null,
    val subtitleUrls: List<String> = emptyList(),
    val route: PlaybackRoute? = null,
    val proxyUrl: String? = null,
    val probe: ProbeResult? = null,
    val error: String? = null,
    val castActive: Boolean = false,
    val sender: String? = null,
) {
    /**
     * Long-form video routing is deliberately narrower than "has a video
     * track": short clips, live/unknown-duration media, HLS, and proxy output
     * must keep the default route-sharing policy.
     */
    val longFormVideoAirPlayEligible: Boolean
        get() {
            if (phase != PlayerPhase.PLAYING || route != PlaybackRoute.DIRECT || proxyUrl != null) return false
            val mediaProbe = probe ?: return false
            if (mediaProbe.isLive || mediaProbe.videoCodec == null) return false
            if (mediaProbe.container.lowercase() in setOf("m3u8", "hls")) return false
            val durationMs = mediaProbe.durationMs ?: return false
            return durationMs >= 60_000L
        }
    val isPlaying: Boolean get() = phase == PlayerPhase.PLAYING
}

/**
 * Single playback orchestrator: intake → probe → FormatRouter → AVPlayer
 * (DIRECT) or local HLS proxy (REMUX/TRANSCODE). Callable from Swift via
 * [RigelIntake].
 */
class PlayerController(
    private val settings: SettingsStore,
) {
    private val tag = "PlayerController"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var directFallbackUsed = false
    private var loadGeneration = 0L
    private var pendingJob: Job? = null
    private var pendingSessionId: String? = null
    private val _uiState = MutableStateFlow(PlayerUiState())
    val uiState: StateFlow<PlayerUiState> = _uiState.asStateFlow()

    private var successCallbackUrl: String? = null

    fun loadRaw(rawUrl: String): Boolean {
        val request = UrlIntake.parse(rawUrl)
        if (request == null) {
            invalidatePendingWork()
            _uiState.value = PlayerUiState(phase = PlayerPhase.ERROR, error = "Unrecognized URL: $rawUrl")
            return false
        }
        loadRequest(request)
        return true
    }

    fun loadRequest(request: IntakeRequest) {
        invalidatePendingWork()
        successCallbackUrl = request.successCallbackUrl
        directFallbackUsed = false
        val generation = loadGeneration
        _uiState.value = PlayerUiState(
            phase = PlayerPhase.PROBING,
            sourceUrl = request.sourceUrl,
            filename = request.filename,
            subtitleUrls = request.subtitleUrls,
            sender = request.xSource,
        )
        pendingJob = scope.launch { probeAndRoute(request, generation) }
    }

    private fun invalidatePendingWork() {
        val sessionId = pendingSessionId ?: _uiState.value.proxyUrl?.let(::extractSessionId)
        loadGeneration += 1
        pendingJob?.cancel()
        pendingJob = null
        if (sessionId != null) {
            Bridges.stopHlsSession(sessionId)
            Bridges.stopHttpServer()
        }
        pendingSessionId = null
    }

    private fun isCurrent(generation: Long): Boolean = generation == loadGeneration

    /**
     * True when a subtitle URL points at an Advanced SubStation file. Only
     * ASS forces the transcode route — HLS cannot carry it without burn-in.
     * Query, fragment, and percent-encoding are stripped so "subs.ass?x=1",
     * "subs.ass#track" and "sub%2Eass" all classify correctly, while
     * "assets/subs.srt" does not.
     */
    private fun isAssSubtitle(url: String): Boolean {
        val path = url.substringBefore('?').substringBefore('#').substringAfterLast('/')
        return percentDecode(path).endsWith(".ass", ignoreCase = true)
    }

    private fun percentDecode(s: String): String = buildString {
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%' && i + 2 < s.length) {
                val hi = s[i + 1].digitToIntOrNull(16)
                val lo = s[i + 2].digitToIntOrNull(16)
                if (hi != null && lo != null) {
                    append((hi * 16 + lo).toChar())
                    i += 3
                    continue
                }
            }
            append(c)
            i += 1
        }
    }

    private suspend fun probeAndRoute(request: IntakeRequest, generation: Long) {
        val (probe, probeError) = Bridges.probe(request.sourceUrl, emptyMap())
        if (!isCurrent(generation)) return
        if (probe == null) {
            Logger.w(tag) { "probe failed: $probeError" }
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                error = probeError ?: "Could not read the stream",
            )
            return
        }
        val override = settings.routeOverride()
        val route = when (override) {
            RouteOverride.DIRECT -> PlaybackRoute.DIRECT
            RouteOverride.ALWAYS_PROXY -> PlaybackRoute.REMUX
            RouteOverride.AUTO -> FormatRouter.decide(probe, hasExternalAssSubs = request.subtitleUrls.any { isAssSubtitle(it) })
        }
        if (!isCurrent(generation)) return
        Logger.i(tag) { "route=$route container=${probe.container} video=${probe.videoCodec} audio=${probe.audioCodecs}" }
        when (route) {
            PlaybackRoute.DIRECT -> {
                _uiState.value = _uiState.value.copy(
                    phase = PlayerPhase.PLAYING,
                    route = PlaybackRoute.DIRECT,
                    proxyUrl = null,
                    probe = probe,
                )
            }
            PlaybackRoute.REMUX, PlaybackRoute.TRANSCODE -> {
                _uiState.value = _uiState.value.copy(
                    phase = PlayerPhase.PREPARING_PROXY,
                    route = route,
                    probe = probe,
                )
                prepareProxy(probe, route, generation)
            }
        }
    }

    private suspend fun prepareProxy(probe: ProbeResult, route: PlaybackRoute, generation: Long) {
        if (!isCurrent(generation)) return
        val sourceUrl = _uiState.value.sourceUrl ?: run {
            _uiState.value = _uiState.value.copy(phase = PlayerPhase.ERROR, error = "No source URL")
            return
        }
        val sessionId = "session-${Random.nextLong().toString(16)}${Random.nextInt(0xFFFF).toString(16)}"
        pendingSessionId = sessionId
        val (relPath, transcodeError) = Bridges.startHlsSession(
            sessionId = sessionId,
            sourceUrl = sourceUrl,
            headers = emptyMap(),
            mode = route.name.lowercase(),
        )
        if (!isCurrent(generation)) {
            Bridges.stopHlsSession(sessionId)
            if (pendingSessionId == sessionId) pendingSessionId = null
            return
        }
        if (relPath == null) {
            if (pendingSessionId == sessionId) pendingSessionId = null
            Logger.w(tag) { "HLS session failed: $transcodeError" }
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                error = transcodeError ?: "Transcode/remux failed",
            )
            return
        }
        val (port, serverError) = Bridges.startHttpServer()
        if (!isCurrent(generation)) {
            Bridges.stopHlsSession(sessionId)
            if (pendingSessionId == null || pendingSessionId == sessionId) Bridges.stopHttpServer()
            if (pendingSessionId == sessionId) pendingSessionId = null
            return
        }
        if (port < 0) {
            if (pendingSessionId == sessionId) pendingSessionId = null
            Logger.w(tag) { "HTTP server failed: $serverError" }
            Bridges.stopHlsSession(sessionId)
            Bridges.stopHttpServer()
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                error = serverError ?: "Local server failed",
            )
            return
        }
        // AirPlay video is remote playback: the TV fetches the HLS playlist and
        // segments itself, so the URL must be reachable from the LAN, not loopback.
        // Loopback is the fallback when no Wi-Fi address is available (still plays locally).
        val host = Bridges.lanBaseUrl() ?: "http://127.0.0.1:$port"
        val proxyUrl = "$host/$relPath"
        if (!isCurrent(generation)) {
            Bridges.stopHlsSession(sessionId)
            if (pendingSessionId == null || pendingSessionId == sessionId) Bridges.stopHttpServer()
            if (pendingSessionId == sessionId) pendingSessionId = null
            return
        }
        pendingSessionId = null
        Logger.i(tag) { "proxy ready: $proxyUrl" }
        _uiState.value = _uiState.value.copy(phase = PlayerPhase.PLAYING, proxyUrl = proxyUrl)
    }

    /** Error retry: force the REMUX proxy path. */
    fun retryWithProxy() {
        val current = _uiState.value
        val sourceUrl = current.sourceUrl ?: return
        invalidatePendingWork()
        directFallbackUsed = true
        val generation = loadGeneration
        _uiState.value = current.copy(phase = PlayerPhase.PROBING, error = null, route = PlaybackRoute.REMUX, proxyUrl = null)
        pendingJob = scope.launch {
            val (probe, _) = Bridges.probe(sourceUrl, emptyMap())
            if (!isCurrent(generation)) return@launch
            if (probe == null) {
                _uiState.value = _uiState.value.copy(phase = PlayerPhase.ERROR, error = "Probe failed again")
                return@launch
            }
            _uiState.value = _uiState.value.copy(probe = probe)
            prepareProxy(probe, PlaybackRoute.REMUX, generation)
        }
    }

    fun stopPlayback() {
        invalidatePendingWork()
        Bridges.stopHttpServer()
        UrlIntake.fireSuccess(successCallbackUrl)
        successCallbackUrl = null
        _uiState.value = PlayerUiState()
    }

    /**
     * Native playback failure seam. A DIRECT failure gets exactly one
     * automatic demotion to the REMUX proxy — probe-based routing can miss
     * profile/level/bit-depth quirks, and a silent auto-recover beats an
     * error screen. Proxy failures surface as errors (no infinite loop).
     */
    fun reportError(message: String) {
        val current = _uiState.value
        // Errors from the player being replaced must not clobber an in-flight
        // proxy build. prepareProxy owns the eventual success/failure state.
        if (current.phase == PlayerPhase.PREPARING_PROXY || current.phase == PlayerPhase.PROBING) return
        if (!directFallbackUsed && current.phase == PlayerPhase.PLAYING &&
            current.route == PlaybackRoute.DIRECT && current.proxyUrl == null && current.probe != null
        ) {
            directFallbackUsed = true
            val generation = loadGeneration
            _uiState.value = current.copy(phase = PlayerPhase.PREPARING_PROXY, route = PlaybackRoute.REMUX, error = null)
            pendingJob = scope.launch {
                prepareProxy(current.probe!!, PlaybackRoute.REMUX, generation)
            }
            return
        }
        _uiState.value = _uiState.value.copy(phase = PlayerPhase.ERROR, error = message)
    }

    private fun extractSessionId(proxyUrl: String): String =
        proxyUrl.substringBeforeLast('/').substringAfterLast('/')
}

/** Exposed to Swift (RigelIntake.shared.handle(url:)) for onOpenURL. */
object RigelIntake {
    private var controller: PlayerController? = null
    private val pending = mutableListOf<String>()

    private fun current(): PlayerController = controller ?: app.rigel.RigelCore.controller

    fun attach(controller: PlayerController) {
        this.controller = controller
        val queued = pending.toList()
        pending.clear()
        for (url in queued) handle(url)
    }

    fun handle(url: String): Boolean {
        val ok = current().loadRaw(url)
        if (!ok && controller == null) {
            pending += url
            return true
        }
        return ok
    }

    /** Test-only: clear attach state and the pending queue. */
    internal fun resetForTest() {
        controller = null
        pending.clear()
    }
}

/** DLNA-renderer receive mode: control-point pushes map onto the same pipeline. */
// RendererEventsImpl lives in iosMain (RendererEvents is an iosMain interface).
