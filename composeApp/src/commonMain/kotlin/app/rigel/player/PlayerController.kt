package app.rigel.player

import app.rigel.cast.CastDispatcher
import app.rigel.cast.CastMediaKind
import app.rigel.cast.CastMediaOrigin
import app.rigel.cast.CastPlaybackPort
import app.rigel.cast.CastTarget
import app.rigel.cast.PreparedCastMedia

import app.rigel.bridge.Bridges
import app.rigel.bridge.ProbeResult
import app.rigel.bridge.SubtitleTrack

import app.rigel.gateway.FormatRouter
import app.rigel.gateway.PlaybackRoute
import app.rigel.gateway.RouteDecision
import app.rigel.intake.IntakeRequest
import app.rigel.intake.JellyfinPlaybackContext
import app.rigel.intake.UrlIntake
import app.rigel.output.DefaultOutputCapabilityResolver
import app.rigel.output.OutputCapabilityResolver
import app.rigel.output.OutputKind
import app.rigel.output.OutputMediaProfile
import app.rigel.output.OutputMediaProfiles
import app.rigel.output.OutputSelection
import app.rigel.output.PlaybackDestination
import app.rigel.output.RemoteUrlPolicy
import app.rigel.settings.RouteOverride
import app.rigel.settings.SettingsStore
import app.rigel.source.jellyfin.JellyfinApi
import app.rigel.source.jellyfin.JellyfinClient
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

enum class PlayerPhase { IDLE, PROBING, PREPARING_PROXY, CONNECTING_OUTPUT, BUFFERING, PLAYING, ERROR }

data class PlayerUiState(
    val phase: PlayerPhase = PlayerPhase.IDLE,
    val sourceUrl: String? = null,
    val filename: String? = null,
    val title: String? = null,
    val subtitleTracks: List<SubtitleTrack> = emptyList(),
    val selectedExternalSubtitleUrl: String? = null,
    val route: PlaybackRoute? = null,
    val proxyUrl: String? = null,
    val probe: ProbeResult? = null,
    val error: String? = null,
    val castActive: Boolean = false,
    val startPositionMs: Long = 0,
    val sender: String? = null,
    val destinationKind: OutputKind = OutputKind.LOCAL,
    val destinationName: String = "This iPhone",
    val destinationId: String = "local:iphone",
    val remotePlayback: Boolean = false,
    val planDetail: String? = null,
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
    private val outputSelection: OutputSelection = OutputSelection(),
    private val capabilityResolver: OutputCapabilityResolver = DefaultOutputCapabilityResolver,
    private val jellyfin: JellyfinClient? = null,
) : CastPlaybackPort {
    private val tag = "PlayerController"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var directFallbackUsed = false
    private var loadGeneration = 0L
    private var pendingJob: Job? = null
    private var pendingSessionId: String? = null
    private var proxySessionSubtitleUrl: String? = null
    private var currentDestination: PlaybackDestination = PlaybackDestination.Local
    private var currentRequest: IntakeRequest? = null
    private var currentPassthroughAudioCodecs: Set<String> = OutputMediaProfiles.local.directAudioCodecs
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
    fun loadJellyfinItem(
        rawUrl: String,
        title: String,
        subtitleTracks: List<SubtitleTrack>,
        baseUrl: String,
        token: String,
        userId: String,
        itemId: String,
    ): Boolean {
        val request = UrlIntake.parse(rawUrl) ?: return false
        loadRequest(
            request.copy(
                title = title,
                subtitleTracks = subtitleTracks,
                jellyfinContext = JellyfinPlaybackContext(baseUrl, token, userId, itemId),
            ),
        )
        return true
    }

    fun loadRequest(request: IntakeRequest, destinationOverride: PlaybackDestination? = null) {
        val staleStop = stopJellyfinIfActive()
        invalidatePendingWork()
        val detachedTarget = CastDispatcher.detachActive()
        val detachedStop = detachedTarget?.let { scope.launch { CastDispatcher.stopDetached(it) } }
        successCallbackUrl = request.successCallbackUrl
        val resolvedTitle = resolveTitle(request)
        settings.addToLinkHistory(request.sourceUrl, resolvedTitle)
        directFallbackUsed = false
        currentRequest = request
        currentDestination = destinationOverride ?: outputSelection.snapshot().destination
        currentPassthroughAudioCodecs = OutputMediaProfiles.local.directAudioCodecs
        val generation = loadGeneration
        _uiState.value = PlayerUiState(
            phase = PlayerPhase.PROBING,
            sourceUrl = request.sourceUrl,
            filename = request.filename,
            title = resolvedTitle,
            subtitleTracks = request.subtitleTracks,
            selectedExternalSubtitleUrl = request.subtitleTracks.firstOrNull { it.url.isNotBlank() }?.url,
            castActive = false,
            startPositionMs = 0,
            sender = request.xSource,
            destinationKind = currentDestination.kind,
            destinationName = currentDestination.displayName,
            destinationId = currentDestination.identityKey,
        )
        val jellyfinTarget = (currentDestination as? PlaybackDestination.Receiver)?.target
            as? CastTarget.JellyfinSessionTarget
        if (jellyfinTarget != null) {
            _uiState.value = _uiState.value.copy(phase = PlayerPhase.CONNECTING_OUTPUT)
            pendingJob = scope.launch {
                awaitStaleStops(staleStop, detachedStop)
                playJellyfin(request, generation, jellyfinTarget)
            }
        } else {
            pendingJob = scope.launch {
                awaitStaleStops(staleStop, detachedStop)
                probeAndRoute(request, generation)
            }
        }
    }
    fun selectLocal(positionMs: Long) = selectDestination(PlaybackDestination.Local, positionMs)

    fun selectAirPlay(routeId: String, name: String, positionMs: Long) =
        selectDestination(PlaybackDestination.AirPlay(routeId, name), positionMs)

    fun selectReceiver(target: CastTarget, positionMs: Long) =
        selectDestination(PlaybackDestination.Receiver(target), positionMs)

    private fun selectDestination(destination: PlaybackDestination, positionMs: Long) {
        when (destination) {
            PlaybackDestination.Local -> outputSelection.selectLocal()
            is PlaybackDestination.AirPlay -> outputSelection.selectAirPlay(destination.routeId, destination.name)
            is PlaybackDestination.Receiver -> outputSelection.selectReceiver(destination.target)
        }
        val request = currentRequest ?: return
        val current = _uiState.value
        val probe = current.probe
        // Leaving a Jellyfin destination must stop that session too; both
        // superseded stops complete before replacement playback is issued.
        val staleStop = stopJellyfinIfActive()
        val detachedStop = CastDispatcher.detachActive()
            ?.let { scope.launch { CastDispatcher.stopDetached(it) } }
        invalidatePendingWork()
        currentDestination = destination
        val duration = probe?.durationMs
        val resume = if (duration != null && duration > 0) positionMs.coerceIn(0, duration) else positionMs.coerceAtLeast(0)
        val generation = loadGeneration
        _uiState.value = current.copy(
            phase = PlayerPhase.PROBING,
            proxyUrl = null,
            castActive = false,
            remotePlayback = false,
            destinationKind = destination.kind,
            destinationName = destination.displayName,
            destinationId = destination.identityKey,
            startPositionMs = resume,
            error = null,
        )
        val jellyfinTarget = (destination as? PlaybackDestination.Receiver)?.target
            as? CastTarget.JellyfinSessionTarget
        if (jellyfinTarget != null) {
            _uiState.value = _uiState.value.copy(phase = PlayerPhase.CONNECTING_OUTPUT)
            pendingJob = scope.launch {
                awaitStaleStops(staleStop, detachedStop)
                playJellyfin(request, generation, jellyfinTarget)
            }
        } else {
            pendingJob = scope.launch {
                awaitStaleStops(staleStop, detachedStop)
                probeAndRoute(request, generation, probe)
            }
        }
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

        val route = (FormatRouter.decide(
            probe = probe,
            profile = OutputMediaProfiles.local,
            hasSelectedExternalSubtitle = true,
            preference = settings.routeOverride(),
        ) as? RouteDecision.Playable)?.route ?: PlaybackRoute.TRANSCODE
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
    private suspend fun playJellyfin(
        request: IntakeRequest,
        generation: Long,
        target: CastTarget.JellyfinSessionTarget,
    ) {
        val context = request.jellyfinContext
        if (context == null) {
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                error = "Jellyfin destinations only support Jellyfin library items",
            )
            return
        }
        val requestBase = JellyfinApi.normalizeServerBase(context.baseUrl)
        if (requestBase != target.serverBase) {
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                error = "Selected Jellyfin client belongs to a different server",
            )
            return
        }
        val client = jellyfin ?: run {
            _uiState.value = _uiState.value.copy(phase = PlayerPhase.ERROR, error = "Jellyfin client is not configured")
            return
        }
        val sent = runCatching {
            client.playToSession(context.baseUrl, context.token, target.session.id, listOf(context.itemId))
        }.getOrDefault(false)
        if (!isCurrent(generation)) return
        if (sent) {
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.PLAYING,
                route = null,
                proxyUrl = null,
                remotePlayback = true,
                castActive = true,
                planDetail = "Jellyfin is choosing direct play or conversion",
            )
        } else {
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                error = "Jellyfin could not start this item on ${target.name}",
            )
        }
    }

    private suspend fun probeAndRoute(
        request: IntakeRequest,
        generation: Long,
        knownProbe: ProbeResult? = null,
    ) {
        val (probe, probeError) = knownProbe?.let { it to null } ?: Bridges.probe(request.sourceUrl, emptyMap())
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
        val destination = currentDestination
        if (destination is PlaybackDestination.Receiver && destination.target is CastTarget.JellyfinSessionTarget) {
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                probe = probe,
                error = "Jellyfin destinations only support Jellyfin library items",
            )
            return
        }
        val profile = when (destination) {
            PlaybackDestination.Local, is PlaybackDestination.AirPlay -> OutputMediaProfiles.local
            is PlaybackDestination.Receiver -> capabilityResolver.profileFor(destination.target)
        }
        val remoteTarget = (destination as? PlaybackDestination.Receiver)?.target
        val remoteReachable = remoteTarget == null || RemoteUrlPolicy.isReceiverFetchable(request.sourceUrl, profile)
        val hasSelectedExternalSubtitle = _uiState.value.selectedExternalSubtitleUrl != null
        val routeDecision = FormatRouter.decide(
            probe = probe,
            profile = profile,
            hasSelectedExternalSubtitle = hasSelectedExternalSubtitle,
            preference = settings.routeOverride(),
            sourceIsRemotelyReachable = remoteReachable,
        )
        if (!isCurrent(generation)) return
        val playable = routeDecision as? RouteDecision.Playable ?: run {
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                probe = probe,
                error = (routeDecision as RouteDecision.Unsupported).message,
            )
            return
        }
        currentPassthroughAudioCodecs = playable.passthroughAudioCodecs
        Logger.i(tag) { "route=${playable.route} destination=${destination.displayName} container=${probe.container} video=${probe.videoCodec} audio=${probe.audioCodecs}" }
        when (playable.route) {
            PlaybackRoute.DIRECT -> {
                _uiState.value = _uiState.value.copy(
                    phase = if (remoteTarget == null) PlayerPhase.PLAYING else PlayerPhase.CONNECTING_OUTPUT,
                    route = PlaybackRoute.DIRECT,
                    proxyUrl = null,
                    probe = probe,
                    planDetail = playable.detail,
                )
                if (remoteTarget == null) {
                    return
                }
                dispatchRemoteDirect(remoteTarget, request.sourceUrl, probe, generation)
            }
            PlaybackRoute.REMUX, PlaybackRoute.TRANSCODE -> {
                _uiState.value = _uiState.value.copy(
                    phase = PlayerPhase.PREPARING_PROXY,
                    route = playable.route,
                    probe = probe,
                    planDetail = playable.detail,
                )
                prepareProxy(probe, playable.route, generation, playable.passthroughAudioCodecs)
            }
        }
    }
    private suspend fun prepareProxy(
        probe: ProbeResult,
        route: PlaybackRoute,
        generation: Long,
        passthroughAudioCodecs: Set<String> = currentPassthroughAudioCodecs,
    ) {
        if (!isCurrent(generation)) return
        // Rebuild paths (seek, subtitle change, retry, fallback) re-derive the
        // receiver here so a remote session never silently drops to local.
        val remoteTarget = (currentDestination as? PlaybackDestination.Receiver)?.target
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
            passthroughAudioCodecs = passthroughAudioCodecs.toList(),
            startOffsetMs = startOffsetMs,
            subtitleTracks = subtitleTracks,
            onError = { message ->
                val error = if (selectedSubtitle) "Could not prepare the selected subtitle" else message
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
            val error = if (selectedSubtitle) "Could not prepare the selected subtitle"
                else transcodeError ?: "Transcode/remux failed"
            _uiState.value = _uiState.value.copy(phase = PlayerPhase.ERROR, error = error)
            return
        }
        val (port, serverError) = Bridges.startHttpServer()
        if (!isCurrent(generation)) {
            Bridges.stopHlsSession(sessionId)
            Bridges.stopHttpServer()
            if (pendingSessionId == sessionId) pendingSessionId = null
            return
        }
        if (port < 0) {
            if (pendingSessionId == sessionId) pendingSessionId = null
            Bridges.stopHlsSession(sessionId)
            Bridges.stopHttpServer()
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                error = serverError ?: "Local server failed",
            )
            return
        }
        val lanBase = Bridges.lanBaseUrl()
        if (remoteTarget != null && lanBase == null) {
            Bridges.stopHlsSession(sessionId)
            Bridges.stopHttpServer()
            if (pendingSessionId == sessionId) pendingSessionId = null
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                error = "No local network address is available for ${remoteTarget.name}",
            )
            return
        }
        val proxyUrl = "${lanBase ?: "http://127.0.0.1:$port"}/$relPath"
        if (!isCurrent(generation)) {
            Bridges.stopHlsSession(sessionId)
            Bridges.stopHttpServer()
            if (pendingSessionId == sessionId) pendingSessionId = null
            return
        }
        pendingSessionId = null
        proxySessionSubtitleUrl = subtitleTracks.firstOrNull()?.url
        if (remoteTarget == null) {
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.PLAYING,
                proxyUrl = proxyUrl,
            )
            return
        }
        val media = PreparedCastMedia(
            url = proxyUrl,
            title = state.title ?: "Stream",
            contentType = "application/vnd.apple.mpegurl",
            container = "m3u8",
            kind = if (probe.videoCodec == null) CastMediaKind.AUDIO else CastMediaKind.VIDEO,
            isLive = probe.isLive,
            origin = CastMediaOrigin.PROXY,
        )
        _uiState.value = _uiState.value.copy(
            phase = PlayerPhase.CONNECTING_OUTPUT,
            proxyUrl = proxyUrl,
        )
        val result = CastDispatcher.cast(remoteTarget, media)
        if (!isCurrent(generation)) {
            Bridges.stopHlsSession(sessionId)
            return
        }
        if (result is app.rigel.cast.CastResult.Sent) {
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.PLAYING,
                proxyUrl = proxyUrl,
                remotePlayback = true,
                castActive = true,
            )
        } else {
            Bridges.stopHlsSession(sessionId)
            Bridges.stopHttpServer()
            if (route != PlaybackRoute.TRANSCODE && !directFallbackUsed) {
                directFallbackUsed = true
                _uiState.value = _uiState.value.copy(
                    phase = PlayerPhase.PREPARING_PROXY,
                    route = PlaybackRoute.TRANSCODE,
                    proxyUrl = null,
                    error = null,
                )
                prepareProxy(probe, PlaybackRoute.TRANSCODE, generation, emptySet())
                return
            }
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.ERROR,
                proxyUrl = null,
                error = result.message,
            )
        }
    }
    private suspend fun dispatchRemoteDirect(
        target: CastTarget,
        sourceUrl: String,
        probe: ProbeResult,
        generation: Long,
    ) {
        if (!isCurrent(generation)) return
        val state = _uiState.value
        val media = PreparedCastMedia(
            url = sourceUrl,
            title = state.title ?: "Stream",
            contentType = contentTypeForProbe(probe),
            container = probe.container.lowercase(),
            kind = if (probe.videoCodec == null) CastMediaKind.AUDIO else CastMediaKind.VIDEO,
            isLive = probe.isLive,
            origin = CastMediaOrigin.SOURCE,
        )
        val result = CastDispatcher.cast(target, media)
        if (!isCurrent(generation)) return
        if (result is app.rigel.cast.CastResult.Sent) {
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.PLAYING,
                remotePlayback = true,
                castActive = true,
            )
            return
        }
        capabilityResolver.invalidate(target)
        if (!directFallbackUsed) {
            directFallbackUsed = true
            currentPassthroughAudioCodecs = emptySet()
            _uiState.value = _uiState.value.copy(
                phase = PlayerPhase.PREPARING_PROXY,
                route = PlaybackRoute.TRANSCODE,
                error = null,
            )
            prepareProxy(probe, PlaybackRoute.TRANSCODE, generation, emptySet())
            return
        }
        _uiState.value = _uiState.value.copy(phase = PlayerPhase.ERROR, error = result.message)
    }

    private fun contentTypeForProbe(probe: ProbeResult): String = when (probe.container.lowercase()) {
        "mp4", "m4v" -> "video/mp4"
        "mov" -> "video/quicktime"
        "m3u8", "hls" -> "application/vnd.apple.mpegurl"
        "mp3" -> "audio/mpeg"
        "m4a" -> "audio/mp4"
        "aac" -> "audio/aac"
        "flac" -> "audio/flac"
        else -> if (probe.videoCodec == null) "audio/mpeg" else "video/mp4"
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
    /** Fire-and-forget stop for the active Jellyfin session; returns the job so replacement playback can await it. */
    private fun stopJellyfinIfActive(): Job? {
        val target = (currentDestination as? PlaybackDestination.Receiver)?.target
            as? CastTarget.JellyfinSessionTarget ?: return null
        val context = currentRequest?.jellyfinContext ?: return null
        val client = jellyfin ?: return null
        return scope.launch { client.stopSession(context.baseUrl, context.token, target.session.id) }
    }

    /** Replacement playback awaits superseded stops so a late stop cannot kill the new session. */
    private suspend fun awaitStaleStops(vararg stops: Job?) {
        stops.forEach { it?.join() }
    }

    fun stopPlayback() {
        stopJellyfinIfActive()
        invalidatePendingWork()
        val detachedTarget = CastDispatcher.detachActive()
        if (detachedTarget != null) scope.launch { CastDispatcher.stopDetached(detachedTarget) }
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

    private fun resolveTitle(request: IntakeRequest): String =
        request.title?.trim()?.takeIf { it.isNotEmpty() }
            ?: request.filename?.trim()?.takeIf { it.isNotEmpty() }
            ?: request.sourceUrl.substringBefore('?').substringAfterLast("/").takeIf { it.isNotEmpty() }
            ?: "Stream"

    private fun extractSessionId(proxyUrl: String): String =
        proxyUrl.substringBeforeLast('/').substringAfterLast('/')
}
