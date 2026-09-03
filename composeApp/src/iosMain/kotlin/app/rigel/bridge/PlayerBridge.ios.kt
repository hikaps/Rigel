package app.rigel.bridge

import platform.UIKit.UIViewController

/**
 * AVPlayer hosting lives in Swift (RigelPlayerViewController) — same pattern as
 * Nuvio's MPVPlayerBridge. Kotlin receives a UIViewController for interop and
 * forwards load/stop calls. Events call back into Kotlin on the main thread.
 */
interface PlayerEvents {
    fun onReady()
    fun onError(message: String)
    fun onBack()
}

interface NativePlayerBridge {
    fun createPlayerViewController(events: PlayerEvents): UIViewController
    fun load(
        url: String,
        title: String?,
        sender: String?,
        longFormVideoAirPlayEligible: Boolean,
        subtitleTracks: List<SubtitleTrack>,
        selectedExternalSubtitleUrl: String?,
        durationMs: Long?,
        isProxy: Boolean,
        startOffsetMs: Long,
    )
    fun stop()
}

object PlayerBridgeFactory {
    private var impl: NativePlayerBridge? = null

    fun register(bridge: NativePlayerBridge) {
        impl = bridge
    }

    fun create(): NativePlayerBridge? = impl

    val isRegistered: Boolean get() = impl != null
}
