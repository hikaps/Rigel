package app.rigel.output

import app.rigel.cast.CastTarget
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class OutputKind {
    LOCAL,
    AIRPLAY,
    DLNA,
    ROKU,
    KODI,
    CHROMECAST,
    JELLYFIN,
}

sealed interface PlaybackDestination {
    val identityKey: String
    val displayName: String
    val kind: OutputKind
    val acceptsUrl: Boolean
    val rendersThroughNativePlayer: Boolean

    data object Local : PlaybackDestination {
        override val identityKey: String = "local:iphone"
        override val displayName: String = "This iPhone"
        override val kind: OutputKind = OutputKind.LOCAL
        override val acceptsUrl: Boolean = true
        override val rendersThroughNativePlayer: Boolean = true
    }

    data class AirPlay(
        val routeId: String,
        val name: String,
    ) : PlaybackDestination {
        override val identityKey: String = "airplay:$routeId"
        override val displayName: String = name.ifBlank { "AirPlay" }
        override val kind: OutputKind = OutputKind.AIRPLAY
        override val acceptsUrl: Boolean = true
        override val rendersThroughNativePlayer: Boolean = true
    }

    data class Receiver(val target: CastTarget) : PlaybackDestination {
        override val identityKey: String get() = target.identityKey
        override val displayName: String get() = target.name
        override val kind: OutputKind get() = target.outputKind
        override val acceptsUrl: Boolean get() = target !is CastTarget.JellyfinSessionTarget
        override val rendersThroughNativePlayer: Boolean = false
    }
}

data class OutputSelectionState(
    val destination: PlaybackDestination = PlaybackDestination.Local,
) {
    val identityKey: String get() = destination.identityKey
    val displayName: String get() = destination.displayName
    val kind: OutputKind get() = destination.kind
    val acceptsUrl: Boolean get() = destination.acceptsUrl
}

/** App-session destination preference. Endpoints and capability profiles are not persisted. */
class OutputSelection {
    private val _state = MutableStateFlow(OutputSelectionState())
    val state: StateFlow<OutputSelectionState> = _state.asStateFlow()

    fun snapshot(): OutputSelectionState = _state.value

    fun selectLocal() {
        _state.value = OutputSelectionState(PlaybackDestination.Local)
    }

    fun selectAirPlay(routeId: String, name: String) {
        if (routeId.isBlank()) return
        _state.value = OutputSelectionState(PlaybackDestination.AirPlay(routeId, name))
    }

    fun selectReceiver(target: CastTarget) {
        _state.value = OutputSelectionState(PlaybackDestination.Receiver(target))
    }

    /** Refresh the selected receiver object without changing the selected identity. */
    fun replaceIfSameIdentity(target: CastTarget): Boolean {
        val current = _state.value.destination
        if (current !is PlaybackDestination.Receiver || current.identityKey != target.identityKey) {
            return false
        }
        _state.value = OutputSelectionState(PlaybackDestination.Receiver(target))
        return true
    }

    fun clearJellyfinServer(serverBase: String) {
        val current = _state.value.destination
        if (current is PlaybackDestination.Receiver &&
            current.target is CastTarget.JellyfinSessionTarget &&
            current.target.serverBase == normalizeServerBase(serverBase)
        ) {
            selectLocal()
        }
    }

    private fun normalizeServerBase(value: String): String = value.trim().trimEnd('/').lowercase()
}

val CastTarget.outputKind: OutputKind
    get() = when (this) {
        is CastTarget.Dlna -> OutputKind.DLNA
        is CastTarget.Roku -> OutputKind.ROKU
        is CastTarget.Kodi -> OutputKind.KODI
        is CastTarget.Chrome -> OutputKind.CHROMECAST
        is CastTarget.JellyfinSessionTarget -> OutputKind.JELLYFIN
    }
