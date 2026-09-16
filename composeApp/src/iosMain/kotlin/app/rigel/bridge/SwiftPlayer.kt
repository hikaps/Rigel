package app.rigel.bridge

import app.rigel.RigelCore
import app.rigel.cast.CastTarget
import app.rigel.player.PlayerUiState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * SwiftUI-facing player facade: state snapshots + change observation.
 * Kotlin owns playback state; the UI observes and renders.
 */
object SwiftPlayer {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    fun snapshot(): PlayerUiState = RigelCore.controller.uiState.value

    /** Fires on the main thread on every state change; cancel the Job to stop observing. */
    fun observe(onChange: (PlayerUiState) -> Unit): Job =
        scope.launch { RigelCore.controller.uiState.collect { onChange(it) } }

    fun loadRaw(
        url: String,
        title: String? = null,
        subtitleTracks: List<SubtitleTrack> = emptyList(),
    ): Boolean = RigelCore.controller.loadRaw(url, title, subtitleTracks)

    fun loadJellyfinItem(
        url: String,
        title: String,
        subtitleTracks: List<SubtitleTrack>,
        baseUrl: String,
        token: String,
        userId: String,
        itemId: String,
    ): Boolean = RigelCore.controller.loadJellyfinItem(url, title, subtitleTracks, baseUrl, token, userId, itemId)

    fun stop() = RigelCore.controller.stopPlayback()

    fun selectLocal(positionMs: Long) = RigelCore.controller.selectLocal(positionMs)

    fun selectAirPlay(routeId: String, name: String, positionMs: Long) =
        RigelCore.controller.selectAirPlay(routeId, name, positionMs)

    fun selectReceiver(target: CastTarget, positionMs: Long) =
        RigelCore.controller.selectReceiver(target, positionMs)

    fun selectExternalSubtitle(track: SubtitleTrack?, positionMs: Long) =
        RigelCore.controller.selectExternalSubtitle(track, positionMs)

    fun retryWithProxy() = RigelCore.controller.retryWithProxy()

    fun seek(positionMs: Long, durationMs: Long) =
        RigelCore.controller.seek(positionMs, durationMs)

    /** Native player (AVPlayerViewController poll) reports item failure. */
    fun reportError(message: String) = RigelCore.controller.reportError(message)
}
