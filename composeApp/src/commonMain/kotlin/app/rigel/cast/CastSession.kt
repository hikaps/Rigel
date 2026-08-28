package app.rigel.cast

import app.rigel.cast.dlna.DlnaDevice
import app.rigel.source.jellyfin.JellyfinSession
import app.rigel.cast.chrome.ChromeDevice
import app.rigel.cast.kodi.KodiDevice
import app.rigel.cast.roku.RokuDevice

sealed interface CastTarget {
    val name: String
    val stableId: String
    val kindLabel: String

    data class Dlna(val device: DlnaDevice) : CastTarget {
        override val name: String get() = device.friendlyName
        override val stableId: String get() = device.usn
        override val kindLabel: String get() = "DLNA"
    }

    data class Roku(val device: RokuDevice) : CastTarget {
        override val name: String get() = device.modelName ?: "Roku"
        override val stableId: String get() = device.usn
        override val kindLabel: String get() = "Roku"
    }

    data class Kodi(val device: KodiDevice) : CastTarget {
        override val name: String get() = device.name ?: "Kodi"
        override val stableId: String get() = device.usn
        override val kindLabel: String get() = "Kodi"
    }

    data class Chrome(val device: ChromeDevice) : CastTarget {
        override val name: String get() = device.name.ifBlank { "Chromecast" }
        override val stableId: String get() = device.id
        override val kindLabel: String get() = "Chromecast"
    }

    data class JellyfinSessionTarget(val session: JellyfinSession) : CastTarget {
        override val name: String get() = session.deviceName
        override val stableId: String get() = session.id
        override val kindLabel: String get() = "Jellyfin"
    }
}

data class CastCapabilities(
    val supportsSeek: Boolean,
    val supportsPosition: Boolean,
    val note: String?,
)

/** Per-adapter control of a remote renderer. */
class CastSession {
    private var active: CastTarget? = null
    private var epoch = 0L

    fun activeTarget(): CastTarget? = active

    fun beginAttempt(): Long {
        epoch += 1
        return epoch
    }

    /**
     * Mint a commit token only when [target] is still the active receiver.
     * Callers pass the token to [commitActive]; a clearActive() between mint
     * and completion bumps the epoch and voids the commit.
     */
    fun beginAttemptFor(target: CastTarget): Long? {
        if (active != target) return null
        return beginAttempt()
    }

    fun commitActive(target: CastTarget, attempt: Long): Boolean {
        if (attempt != epoch) return false
        active = target
        return true
    }

    fun clearActive() {
        epoch += 1
        active = null
    }

    fun capabilities(target: CastTarget): CastCapabilities =
        ReceiverRegistry.adapterFor(target).capabilities()
}
