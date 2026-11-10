package app.rigel.cast.chrome

import app.rigel.bridge.BridgeSlot
import app.rigel.cast.ChromeDevice

/** Native transport pipe; CASTV2 framing and protocol sequencing stay in common Kotlin. */
interface CastWireConnection {
    fun send(frame: ByteArray)
    fun close()
}

/** iOS implementation uses NWBrowser + NWConnection; JVM tests register a fake. */
interface ChromecastBridge {
    fun discover(timeoutMs: Int, onResult: (List<ChromeDevice>) -> Unit)
    fun open(
        host: String,
        port: Int,
        onFrame: (ByteArray) -> Unit,
        onError: (String) -> Unit,
        onOpen: (CastWireConnection?, errorMsg: String?) -> Unit,
    )
}

/** Mutable startup registry, matching the existing native bridge factories. */
object ChromecastBridgeFactory {
    private val slot = BridgeSlot<ChromecastBridge>()

    fun register(bridge: ChromecastBridge?) {
        slot.register(bridge)
    }

    val current: ChromecastBridge? get() = slot.current
}
