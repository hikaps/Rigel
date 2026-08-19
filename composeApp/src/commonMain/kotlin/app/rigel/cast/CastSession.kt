package app.rigel.cast

import app.rigel.cast.dlna.DlnaDevice
import app.rigel.cast.kodi.KodiDevice
import app.rigel.cast.roku.RokuDevice

sealed interface CastTarget {
    val name: String

    data class Dlna(val device: app.rigel.cast.dlna.DlnaDevice) : CastTarget {
        override val name: String get() = device.friendlyName
    }

    data class Roku(val device: RokuDevice) : CastTarget {
        override val name: String get() = device.modelName ?: "Roku"
    }

    data class Kodi(val device: KodiDevice) : CastTarget {
        override val name: String get() = device.name ?: "Kodi"
    }

    data class JellyfinSessionTarget(val session: app.rigel.source.jellyfin.JellyfinSession) : CastTarget {
        override val name: String get() = session.deviceName
    }
}

data class CastCapabilities(
    val supportsSeek: Boolean,
    val supportsPosition: Boolean,
    val note: String?,
)

/** Per-adapter control of a remote renderer. */
class CastSession {
    fun capabilities(target: CastTarget): CastCapabilities = when (target) {
        is CastTarget.Dlna -> CastCapabilities(
            supportsSeek = true,
            supportsPosition = true,
            note = null,
        )
        is CastTarget.Roku -> CastCapabilities(
            supportsSeek = false,
            supportsPosition = false,
            note = "Roku ECP media playback has no seek or position tracking",
        )
        is CastTarget.Kodi -> CastCapabilities(
            supportsSeek = true,
            supportsPosition = true,
            note = null,
        )
        is CastTarget.JellyfinSessionTarget -> CastCapabilities(
            supportsSeek = false,
            supportsPosition = false,
            note = "Jellyfin session remote control plays library items; no seek/position",
        )
    }
}
