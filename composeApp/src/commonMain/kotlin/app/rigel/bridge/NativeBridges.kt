package app.rigel.bridge

/**
 * Bridge interfaces implemented by the Swift side (iosApp/Bridge).
 * Mirrors the Nuvio PlayerBridge pattern: Kotlin interface + factory
 * registration from Swift at app startup.
 */

data class SsdpDevice(
    val usn: String,
    val location: String,
    val server: String?,
    val searchTarget: String,
)

data class ProbeResult(
    val container: String,
    val videoCodec: String?,
    val audioCodecs: List<String>,
    val subtitleCodecs: List<String>,
    val durationMs: Long?,
    val isLive: Boolean,
    val pixFmt: String? = null,
    val width: Int = 0,
    val height: Int = 0,
)

interface DiscoveryBridge {
    fun ssdpSearch(searchTargets: List<String>, timeoutMs: Int, onResult: (List<SsdpDevice>) -> Unit)
}

interface ProbeBridge {
    fun probe(url: String, headers: Map<String, String>, onResult: (ProbeResult?, errorMsg: String?) -> Unit)
}

interface TranscodeBridge {
    fun startHlsSession(
        sessionId: String,
        sourceUrl: String,
        headers: Map<String, String>,
        mode: String,
        onReady: (relativePlaylistPath: String?, errorMsg: String?) -> Unit,
        onError: (errorMsg: String) -> Unit,
    )

    fun stopHlsSession(sessionId: String)
}

interface HttpServerBridge {
    /** port == -1 on failure (non-null Long exports as scalar int64_t). */
    fun start(onStarted: (port: Long, errorMsg: String?) -> Unit)

    fun stop()

    fun lanBaseUrl(): String?
}

/** Registry mirroring NuvioPlayerBridgeFactory; Swift calls [register] at startup. */
object RigelBridgeFactory {
    private var discoveryImpl: DiscoveryBridge? = null
    private var probeImpl: ProbeBridge? = null
    private var transcodeImpl: TranscodeBridge? = null
    private var httpServerImpl: HttpServerBridge? = null

    fun register(
        discovery: DiscoveryBridge?,
        probe: ProbeBridge?,
        transcode: TranscodeBridge?,
        httpServer: HttpServerBridge?,
    ) {
        discoveryImpl = discovery
        probeImpl = probe
        transcodeImpl = transcode
        httpServerImpl = httpServer
    }

    val discovery: DiscoveryBridge? get() = discoveryImpl
    val probe: ProbeBridge? get() = probeImpl
    val transcode: TranscodeBridge? get() = transcodeImpl
    val httpServer: HttpServerBridge? get() = httpServerImpl

    val isRegistered: Boolean
        get() = discoveryImpl != null && probeImpl != null && transcodeImpl != null && httpServerImpl != null
}

/** Common-facing access to the DLNA renderer receive mode (iosMain actual). */
expect object RendererBridgeAccess {
    /** Returns null on success, or an error message (e.g. missing multicast entitlement). */
    fun start(): String?

    fun stop()

    fun isRunning(): Boolean
}
