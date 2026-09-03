package app.rigel.bridge

/** iosMain actual for RendererBridgeAccess — delegates to the Swift renderer service. */
actual object RendererBridgeAccess {
    private val events = RendererEventsImpl

    actual fun start(): String? =
        RendererBridgeFactory.create()?.start(events) ?: "Renderer bridge not registered"

    actual fun stop() {
        RendererBridgeFactory.create()?.stop()
    }

    actual fun isRunning(): Boolean =
        RendererBridgeFactory.create()?.isRunning() ?: false
}

/** DLNA-renderer receive mode: control-point pushes map onto the normal intake pipeline. */
object RendererEventsImpl : RendererEvents {
    override fun onSetUri(uri: String, title: String?) {
        app.rigel.intake.RigelIntake.handle(uri, title)
    }

    override fun onPlay() {
        // AVPlayer already plays on load; no-op (control point issued SetAVTransportURI+Play).
    }

    override fun onPause() {
        // Player pause not exposed on the bridge yet; no-op for v1.
    }

    override fun onStop() {
        app.rigel.RigelCore.controller.stopPlayback()
    }
}
