package app.rigel.player

import app.rigel.cast.CastDispatcher
import app.rigel.cast.CastPlaybackPort

import app.rigel.bridge.Bridges
import app.rigel.bridge.ProbeResult
import app.rigel.bridge.SubtitleTrack

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

enum class PlayerPhase { IDLE, PROBING, PREPARING_PROXY, BUFFERING, PLAYING, ERROR }

data class PlayerUiState(
    val phase: PlayerPhase = PlayerPhase.IDLE,
    val sourceUrl: String? = null,
    val filename: String? = null,
    val subtitleTracks: List<SubtitleTrack> = emptyList(),
    val selectedExternalSubtitleUrl: String? = null,
    val route: PlaybackRoute? = null,
    val proxyUrl: String? = null,
    val probe: ProbeResult? = null,
    val error: String? = null,
    val castActive: Boolean = false,
    val startPositionMs: Long = 0,
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
) : CastPlaybackPort {
    private val tag = "PlayerController"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var directFallbackUsed = false
    private var loadGeneration = 0L
    private var pendingJob: Job? = null
    private var pendingSessionId: String? = null
    /** Subtitle URL baked into the live proxy playlist, if any. */
    private var proxySessionSubtitleUrl: String? = null
    private val _uiState = MutableStateFlow(PlayerUiState())
    val uiState: StateFlow<PlayerUiState> = _uiState.asStateFlow()

    private var successCallbackUrl: String? = null

    fun loadRaw(
        rawUrl: String,
        title: String? = null,
        subtitleTracks: List<SubtitleTrack> = emptyList(),
    ): Boolean {
        val request = UrlIntake.parse(rawUrl)
        if (request == null) {
            invalidatePendingWork()
            _uiState.value = PlayerUiState(phase = PlayerPhase.ERROR, error = "Unrecognized URL: $rawUrl")
            return false
        }
        val finalTracks = if (subtitleTracks.isNotEmpty()) subtitleTracks else request.subtitleTracks
        loadRequest(request.copy(title = title, subtitleTracks = finalTracks))
        return true
    }


    fun loadRequest(request: IntakeRequest) {
        invalidatePendingWork()
        CastDispatcher.clearActive()
        successCallbackUrl = request.successCallbackUrl
        settings.addToLinkHistory(request.sourceUrl, request.title ?: request.filename)
        directFallbackUsed = false
        val generation = loadGeneration
        _uiState.value = PlayerUiState(
            phase = PlayerPhase.PROBING,
            sourceUrl = request.sourceUrl,
            filename = request.filename,
            subtitleTracks = request.subtitleTracks,
            selectedExternalSubtitleUrl = request.subtitleTracks.firstOrNull { it.url.isNotBlank() }?.url,
            castActive = false,
            startPositionMs = 0,
            sender = request.xSource,
        )
        pendingJob = scope.launch { probeAndRoute(request, generation) }
    }

    override fun setCastActive(active: Boolean) {
        _uiState.value = _uiState.value.copy(castActive = active)
    }

    override fun remoteCastUrl(): String? {
        val state = _uiState.value
        return CastDispatcher.remoteCastUrl(
            isPlaying = state.phase == PlayerPhase.PLAYING,
            proxyUrl = state.proxyUrl,
            sourceUrl = state.sourceUrl,
        )
    }

    override fun remoteCastTitle(): String {
        val state = _uiState.value
        return CastDispatcher.remoteCastTitle(state.filename, state.sourceUrl)
    }

    /**
     * Selects an external text subtitle. Video playback is rebuilt through the
     * LAN HLS proxy so AVPlayer and AirPlay can select the generated rendition.
     */
    fun selectExternalSubtitle(track: SubtitleTrack?, positionMs: Long) {
        val current = _uiState.value
        if (current.phase == PlayerPhase.IDLE) return
        if (track == null) {
            val cleared = current.copy(selectedExternalSubtitleUrl = null)
            // The live playlist may still mark the sidecar DEFAULT=YES: a
            // local Off never rebuilt it, and a remote renderer fetches that
            // same master and keeps its own subtitle selection. Rebuild
            // without the sidecar whenever the running session includes it,
            // local or cast, so no receiver inherits disabled captions.
            if (proxySessionSubtitleUrl == null || current.proxyUrl == null) {
                _uiState.value = cleared
                return
            }
            val probe = current.probe ?: run {
                _uiState.value = cleared
                return
            }
            val route = current.route ?: PlaybackRoute.REMUX
            val target = probe.durationMs?.let { positionMs.coerceIn(0, it) }
                ?: positionMs.coerceAtLeast(0)
            invalidatePendingWork()
            directFallbackUsed = false
            val generation = loadGeneration
            _uiState.value = cleared.copy(
                phase = PlayerPhase.PREPARING_PROXY,
                route = route,
                proxyUrl = null,
                startPositionMs = target,
            )
            pendingJob = scope.launch { prepareProxy(probe, route, generation) }
            return
        }
        if (track.url.isBlank()) return

        val tracks = if (current.subtitleTracks.any { it.url == track.url }) {
            current.subtitleTracks
        } else {
            current.subtitleTracks + track
        }
        val selected = current.copy(
            subtitleTracks = tracks,
            selectedExternalSubtitleUrl = track.url,
            error = null,
        )
        val probe = selected.probe ?: run {
            _uiState.value = selected
            return
        }
        if (probe.videoCodec == null) {
            _uiState.value = selected
            return
        }

        val route = FormatRouter.decide(probe, hasSelectedExternalSubtitle = true)
        if (route == PlaybackRoute.DIRECT) {
            _uiState.value = selected
            return
        }
        val target = probe.durationMs?.let { positionMs.coerceIn(0, it) }
            ?: positionMs.coerceAtLeast(0)
        invalidatePendingWork()
        directFallbackUsed = false
        val generation = loadGeneration
        _uiState.value = selected.copy(
            phase = PlayerPhase.PREPARING_PROXY,
            route = route,
            proxyUrl = null,
            startPositionMs = target,
        )
        pendingJob = scope.launch { prepareProxy(probe, route, generation) }
    }

    fun seek(positionMs: Long, durationMs: Long) {
        val current = _uiState.value
        if (current.phase != PlayerPhase.PLAYING && current.phase != PlayerPhase.BUFFERING) return
        val duration = durationMs.takeIf { it > 0 } ?: current.probe?.durationMs
        val target = if (duration != null && duration > 0) {
            positionMs.coerceIn(0, duration)
        } else {
            positionMs.coerceAtLeast(0)
        }
        if (current.proxyUrl != null) {
            restartProxyAt(target)
        } else if (current.castActive) {
            scope.launch { CastDispatcher.seekActive(target, duration ?: 0) }
        }
    }

    private fun restartProxyAt(positionMs: Long) {
        val current = _uiState.value
        val probe = current.probe ?: return
        val route = current.route ?: return
        val target = probe.durationMs?.let { positionMs.coerceIn(0, it) }
            ?: positionMs.coerceAtLeast(0)
        invalidatePendingWork()
        val generation = loadGeneration
        directFallbackUsed = false
        _uiState.value = current.copy(
            phase = PlayerPhase.BUFFERING,
            error = null,
            startPositionMs = target,
        )
        pendingJob = scope.launch { prepareProxy(probe, route, generation) }
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
        proxySessionSubtitleUrl = null
    }

    private fun isCurrent(generation: Long): Boolean = generation == loadGeneration


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
        if (_uiState.value.selectedExternalSubtitleUrl != null && probe.videoCodec == null) {
            _uiState.value = _uiState.value.copy(selectedExternalSubtitleUrl = null)
        }
        val hasSelectedExternalSubtitle = _uiState.value.selectedExternalSubtitleUrl != null
        val route = if (hasSelectedExternalSubtitle && probe.videoCodec != null) {
            FormatRouter.decide(probe, hasSelectedExternalSubtitle = true)
        } else {
            when (val override = settings.routeOverride()) {
                RouteOverride.DIRECT -> PlaybackRoute.DIRECT
                RouteOverride.ALWAYS_PROXY -> PlaybackRoute.REMUX
                RouteOverride.AUTO -> FormatRouter.decide(
                    probe,
                    hasSelectedExternalSubtitle = false,
                )
            }
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
        val state = _uiState.value
        val subtitleTracks = if (probe.videoCodec == null) {
            emptyList()
        } else {
            state.selectedExternalSubtitleUrl?.let { selectedUrl ->
                state.subtitleTracks.firstOrNull { it.url == selectedUrl }?.let(::listOf)
                    ?: run {
                        _uiState.value = state.copy(
                            phase = PlayerPhase.ERROR,
                            proxyUrl = null,
                            error = "Could not prepare the selected subtitle",
                        )
                        return
                    }
            } ?: emptyList()
        }
        val sessionId = "session-${Random.nextLong().toString(16)}${Random.nextInt(0xFFFF).toString(16)}"
        val startOffsetMs = state.startPositionMs
        pendingSessionId = sessionId
        val selectedSubtitle = subtitleTracks.isNotEmpty()
        val (relPath, transcodeError) = Bridges.startHlsSession(
            sessionId = sessionId,
            sourceUrl = sourceUrl,
            headers = emptyMap(),
            mode = route.name.lowercase(),
            startOffsetMs = startOffsetMs,
            subtitleTracks = subtitleTracks,
            onError = { message ->
                val error = if (selectedSubtitle) {
                    "Could not prepare the selected subtitle"
                } else {
                    message
                }
                scope.launch { failProxySession(sessionId, generation, error) }
            },
        )

        if (!isCurrent(generation)) {
            Bridges.stopHlsSession(sessionId)
            if (pendingSessionId == sessionId) pendingSessionId = null
            return
        }
        if (relPath == null) {
            if (pendingSessionId == sessionId) pendingSessionId = null
            val error = if (selectedSubtitle) {
                "Could not prepare the selected subtitle"
            } else {
                transcodeError ?: "Transcode/remux failed"
            }
            Logger.w(tag) { "HLS session failed: $error" }
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                error = error,
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
        proxySessionSubtitleUrl = subtitleTracks.firstOrNull()?.url
        Logger.i(tag) { "proxy ready: $proxyUrl" }
        val activeTarget = if (_uiState.value.castActive) CastDispatcher.activeTarget() else null
        _uiState.value = _uiState.value.copy(phase = PlayerPhase.PLAYING, proxyUrl = proxyUrl)
        if (activeTarget != null) {
            val state = _uiState.value
            val remoteUrl = CastDispatcher.remoteCastUrl(
                isPlaying = state.phase == PlayerPhase.PLAYING,
                proxyUrl = state.proxyUrl,
                sourceUrl = state.sourceUrl,
            )
            if (remoteUrl != null) {
                scope.launch {
                    runCatching {
                        CastDispatcher.recastIfActive(
                            activeTarget,
                            remoteUrl,
                            CastDispatcher.remoteCastTitle(state.filename, state.sourceUrl),
                        )
                    }.onFailure { error ->
                        Logger.w(tag) { "proxy recast failed: ${error.message}" }
                    }
                }
            }
        }
    }
    private fun failProxySession(sessionId: String, generation: Long, message: String) {
        if (!isCurrent(generation)) return
        loadGeneration += 1
        pendingJob?.cancel()
        pendingJob = null
        if (pendingSessionId == sessionId) pendingSessionId = null
        Bridges.stopHlsSession(sessionId)
        Bridges.stopHttpServer()
        _uiState.value = _uiState.value.copy(phase = PlayerPhase.ERROR, error = message)
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
        CastDispatcher.clearActive()
        Bridges.stopHttpServer()
        UrlIntake.fireSuccess(successCallbackUrl)
        successCallbackUrl = null
        _uiState.value = PlayerUiState()
    }

    /**
     * Native playback failure seam. A DIRECT decoder failure gets exactly one
     * automatic demotion to the TRANSCODE proxy. REMUX would preserve the
     * incompatible bitstream and fail a second time. Proxy failures surface
     * as errors (no infinite loop).
     */
    fun reportError(message: String) {
        val current = _uiState.value
        // Errors from the player being replaced must not clobber an in-flight
        // proxy build. prepareProxy owns the eventual success/failure state.
        if (current.phase == PlayerPhase.PREPARING_PROXY ||
            current.phase == PlayerPhase.PROBING ||
            current.phase == PlayerPhase.BUFFERING
        ) return
        if (!directFallbackUsed && current.phase == PlayerPhase.PLAYING &&
            current.route == PlaybackRoute.DIRECT && current.proxyUrl == null && current.probe != null
        ) {
            directFallbackUsed = true
            val generation = loadGeneration
            _uiState.value = current.copy(phase = PlayerPhase.PREPARING_PROXY, route = PlaybackRoute.TRANSCODE, error = null)
            pendingJob = scope.launch {
                prepareProxy(current.probe!!, PlaybackRoute.TRANSCODE, generation)
            }
            return
        }
        _uiState.value = _uiState.value.copy(phase = PlayerPhase.ERROR, error = message)
    }

    private fun extractSessionId(proxyUrl: String): String =
        proxyUrl.substringBeforeLast('/').substringAfterLast('/')
}
