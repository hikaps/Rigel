package app.rigel.cast.chrome

/** Device discovered through Google Cast mDNS or entered manually. */
data class ChromeDevice(
    val id: String,
    val host: String,
    val port: Int,
    val name: String,
)

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
    internal var bridge: ChromecastBridge? = null

    fun register(bridge: ChromecastBridge?) {
        this.bridge = bridge
    }
}
