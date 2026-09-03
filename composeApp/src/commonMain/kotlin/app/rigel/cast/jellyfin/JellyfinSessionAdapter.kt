package app.rigel.cast.jellyfin

import app.rigel.bridge.SsdpDevice
import app.rigel.cast.CastCapabilities
import app.rigel.cast.CastResult
import app.rigel.cast.CastTarget
import app.rigel.cast.ReceiverAdapter
import app.rigel.source.jellyfin.JellyfinSession
import io.ktor.client.HttpClient

/**
 * Jellyfin sessions are not discovered or manually added;
 * the production UI bypasses CastDispatcher entirely.
 * This adapter exists so the registry covers every CastTarget variant.
 */
object JellyfinSessionAdapter : ReceiverAdapter {
    override val kind = "jellyfin"

    override fun capabilities() = CastCapabilities(
        supportsSeek = false,
        supportsPosition = false,
        note = "Jellyfin session remote control plays library items; no seek/position",
    )

    override suspend fun cast(
        target: CastTarget,
        url: String,
        title: String,
        client: HttpClient,
    ): CastResult = CastResult.Rejected("Jellyfin clients accept library items only — cast from the Sources tab")

    // fromSsdp/fromRow/probeManual stay null: Jellyfin is source-specific, not a discoverable renderer.

    override fun rowFor(target: CastTarget): String {
        val s = (target as CastTarget.JellyfinSessionTarget).session
        return "jellyfin||${s.deviceName}|"
    }

    override fun removalPrefix(target: CastTarget): String = "jellyfin|"
}
