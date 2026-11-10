package app.rigel.cast.jellyfin

import app.rigel.bridge.SsdpDevice
import app.rigel.cast.CastCapabilities
import app.rigel.cast.CastResult
import app.rigel.cast.CastTarget
import app.rigel.cast.PreparedCastMedia
import app.rigel.cast.ReceiverAdapter
import app.rigel.source.jellyfin.JellyfinSession
import io.ktor.client.HttpClient

/**
 * Jellyfin sessions are discovered by DevicesRepository through the signed-in server,
 * not SSDP or manual-IP probing. Library playback uses Jellyfin session commands;
 * this adapter rejects generic URL casting.
 */
object JellyfinSessionAdapter : ReceiverAdapter {
    override val kind = "jellyfin"

    override fun capabilities() = CastCapabilities(
        supportsSeek = false,
        supportsPosition = false,
        supportsPauseResume = false,
        supportsStop = false,
        supportsVolume = false,
        note = "Jellyfin session remote control plays library items; no seek/position",
    )

    override suspend fun cast(
        target: CastTarget,
        media: PreparedCastMedia,
        client: HttpClient,
    ): CastResult = CastResult.Rejected("Jellyfin clients accept library items only — cast from the Sources tab")

    // fromSsdp/fromRow/probeManual stay null: sessions come from the Jellyfin server.

    override fun rowFor(target: CastTarget): String {
        val s = (target as CastTarget.JellyfinSessionTarget).session
        return "jellyfin||${s.deviceName}|"
    }

    override fun removalPrefix(target: CastTarget): String = "jellyfin|"
}
