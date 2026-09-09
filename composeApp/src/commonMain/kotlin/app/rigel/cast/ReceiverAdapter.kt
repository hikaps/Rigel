package app.rigel.cast

import app.rigel.bridge.SsdpDevice
import io.ktor.client.HttpClient

/**
 * Per-receiver-family contract. Each adapter owns discovery enrichment,
 * manual-IP probing, cast dispatch, persistence encoding, and capabilities.
 * [ReceiverRegistry] iterates adapters in declaration order to preserve
 * probe priority (Kodi before DLNA) and scan output ordering.
 */
interface ReceiverAdapter {
    /** Persisted manual-row kind string ("dlna", "roku", "kodi", "chrome", …). */
    val kind: String

    /** SSDP search-target values this family contributes to discovery. */
    val ssdpTargets: List<String> get() = emptyList()

    fun capabilities(): CastCapabilities

    /** Send a URL to the remote renderer; [CastResult.message] is user-facing. */
    suspend fun cast(target: CastTarget, url: String, title: String, client: HttpClient): CastResult
    /** Seek the active remote item; false means this receiver cannot seek. */
    suspend fun seek(
        target: CastTarget,
        positionMs: Long,
        durationMs: Long,
        client: HttpClient,
    ): Boolean = false

    /** Pause the active remote item; false means this receiver cannot pause. */
    suspend fun pause(target: CastTarget, client: HttpClient): Boolean = false

    /** Resume the paused remote item; false means this receiver cannot resume. */
    suspend fun resume(target: CastTarget, client: HttpClient): Boolean = false

    /** Stop the remote item; false means this receiver cannot stop. */
    suspend fun stop(target: CastTarget, client: HttpClient): Boolean = false

    /**
     * Raise the receiver volume one relative step; false means unsupported.
     * Families without absolute volume (Roku) only step up/down/toggle.
     */
    suspend fun volumeUp(target: CastTarget, client: HttpClient): Boolean = false

    /** Lower the receiver volume one relative step; false means unsupported. */
    suspend fun volumeDown(target: CastTarget, client: HttpClient): Boolean = false

    /** Toggle the receiver mute; false means unsupported. */
    suspend fun toggleMute(target: CastTarget, client: HttpClient): Boolean = false

    /** Enrich an SSDP response into a [CastTarget], or null to skip. */
    suspend fun fromSsdp(device: SsdpDevice, client: HttpClient): CastTarget? = null

    /** Decode a persisted manual row (split on '|') into a target, or null. */
    suspend fun fromRow(parts: List<String>, client: HttpClient): CastTarget? = null

    /** Probe a manual IP address; return a target or null. */
    suspend fun probeManual(ip: String, client: HttpClient): CastTarget? = null

    /** Encode a target into the persisted row format "kind|usn|location|name". */
    fun rowFor(target: CastTarget): String

    /**
     * Prefix used by [SettingsStore.removeManualDevice] to filter rows.
     * Default uses kind + stableId; Jellyfin overrides to whole-kind prefix.
     */
    fun removalPrefix(target: CastTarget): String = "$kind|${target.stableId}|"
}
