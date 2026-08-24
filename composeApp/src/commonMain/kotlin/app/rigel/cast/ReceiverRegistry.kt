package app.rigel.cast

import app.rigel.cast.chrome.ChromeAdapter
import app.rigel.cast.dlna.DlnaAdapter
import app.rigel.cast.jellyfin.JellyfinSessionAdapter
import app.rigel.cast.kodi.KodiAdapter
import app.rigel.cast.roku.RokuAdapter

/**
 * Ordered list of receiver adapters. Order matters:
 * - SSDP search targets are collected in list order.
 * - Per-response enrichment tries adapters in order (Kodi before DLNA).
 * - Manual-IP probing tries adapters in order (Kodi :8080 → DLNA → Roku).
 *
 * [adapterFor] is the single exhaustive `when` — adding a receiver variant
 * still requires a branch here (compiler-forced), but all other
 * dispatch/discovery/persistence sites delegate through the returned adapter.
 */
object ReceiverRegistry {
    val adapters: List<ReceiverAdapter> = listOf(
        KodiAdapter,
        DlnaAdapter,
        RokuAdapter,
        ChromeAdapter,
        JellyfinSessionAdapter,
    )

    fun adapterFor(target: CastTarget): ReceiverAdapter = when (target) {
        is CastTarget.Kodi -> KodiAdapter
        is CastTarget.Dlna -> DlnaAdapter
        is CastTarget.Roku -> RokuAdapter
        is CastTarget.Chrome -> ChromeAdapter
        is CastTarget.JellyfinSessionTarget -> JellyfinSessionAdapter
    }
}
