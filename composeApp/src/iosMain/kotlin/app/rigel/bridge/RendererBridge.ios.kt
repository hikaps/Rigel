package app.rigel.bridge

/**
 * DLNA-renderer receive mode (Rigel appears as a UPnP MediaRenderer so
 * Kodi "Play using…", BubbleUPnP, Jellyfin-web can push playback TO Rigel).
 * Requires the com.apple.developer.networking.multicast entitlement (SSDP
 * responder must join the multicast group); start() reports the failure.
 */
interface RendererEvents {
    fun onSetUri(uri: String, title: String?)
    fun onPlay()
    fun onPause()
    fun onStop()
}

interface RendererBridge {
    /** Returns null on success, or an error message (e.g. missing multicast entitlement). */
    fun start(events: RendererEvents): String?

    fun stop()

    fun isRunning(): Boolean
}

object RendererBridgeFactory {
    private val slot = BridgeSlot<RendererBridge>()

    fun register(bridge: RendererBridge) {
        slot.register(bridge)
    }

    fun create(): RendererBridge? = slot.current
}
