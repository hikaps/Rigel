package app.rigel.bridge

/** JVM actual: no renderer receive mode on the desktop test target. */
actual object RendererBridgeAccess {
    actual fun start(): String? = "Renderer receive mode is not supported on this platform"
    actual fun stop() = Unit
    actual fun isRunning(): Boolean = false
}
