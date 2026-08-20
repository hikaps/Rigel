package app.rigel.bridge

import app.rigel.RigelCore
import app.rigel.player.PlayerUiState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
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

    /** Fires on the main thread on every state change. */
    fun observe(onChange: (PlayerUiState) -> Unit) {
        scope.launch { RigelCore.controller.uiState.collect { onChange(it) } }
    }

    fun loadRaw(url: String): Boolean = RigelCore.controller.loadRaw(url)

    fun stop() = RigelCore.controller.stopPlayback()

    fun retryWithProxy() = RigelCore.controller.retryWithProxy()

    /** Native player (AVPlayerViewController poll) reports item failure. */
    fun reportError(message: String) = RigelCore.controller.reportError(message)
}
